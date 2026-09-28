defmodule Knra.ApiClients do
  @moduledoc """
  Organisations allowed to call the container status API (KenTrade, shipping
  lines, terminal operators, ...). Each has its own client code, username and
  password and can be revoked on its own.

  Authentication scheme (same as KenTrade's PGA API):

      From: <client code>
      Authorization: Basic <sha256_hex("username:password")>

  Only `sha256_hex(<that token>)` is stored. The password is generated here and
  shown once when the client is created or its credentials are reset.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Accounts.Policy
  alias Knra.ApiClients.Client

  def list_clients, do: Repo.all(from c in Client, order_by: [asc: c.status, asc: c.name])
  def get_client!(id), do: Repo.get!(Client, id)
  def change_client(client \\ %Client{}, attrs \\ %{}), do: Client.changeset(client, attrs)

  @doc """
  Registers a client. Returns `{:ok, client, password}`; the password is not
  stored and cannot be shown again. A password may be supplied (e.g. to keep
  credentials already given to a partner); otherwise one is generated.
  """
  def create_client(scope, attrs, password \\ nil) do
    with :ok <- authorize(scope) do
      password = password || generate_password()
      username = attrs["username"] || attrs[:username]

      %Client{created_by_id: actor_id(scope)}
      |> Client.changeset(attrs)
      |> Ecto.Changeset.put_change(:token_hash, token_hash(username, password))
      |> insert_audited(scope)
      |> case do
        {:ok, client} -> {:ok, client, password}
        error -> error
      end
    end
  end

  @doc "Issues a new password; the old one stops working immediately."
  def reset_credentials(scope, %Client{} = client) do
    with :ok <- authorize(scope) do
      password = generate_password()

      Repo.transaction(fn ->
        updated =
          client
          |> Ecto.Changeset.change(token_hash: token_hash(client.username, password))
          |> Repo.update!()

        Audit.log(scope, :api_client, client.client_code, "API credentials reset", client.name)
        {updated, password}
      end)
      |> case do
        {:ok, {c, pw}} -> {:ok, c, pw}
        error -> error
      end
    end
  end

  def set_status(scope, %Client{} = client, status) when status in ~w(active revoked) do
    with :ok <- authorize(scope) do
      Repo.transaction(fn ->
        # force_change: always write, even if the caller holds a stale struct
        updated =
          client
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.force_change(:status, status)
          |> Repo.update!()

        Audit.log(
          scope,
          :api_client,
          client.client_code,
          if(status == "revoked", do: "API access revoked", else: "API access restored"),
          client.name
        )

        updated
      end)
    end
  end

  @doc """
  Returns the active client for the `From` code and `Authorization` header value,
  or nil. Compares hashes in constant time.
  """
  def authenticate(client_code, authorization) do
    with code when code not in [nil, ""] <- client_code,
         "Basic " <> token <- authorization || "",
         %Client{status: "active"} = client <-
           Repo.get_by(Client, client_code: String.upcase(String.trim(code))),
         true <- Plug.Crypto.secure_compare(hash(String.downcase(token)), client.token_hash) do
      client
    else
      _ -> nil
    end
  end

  def touch(%Client{id: id}) do
    Repo.update_all(from(c in Client, where: c.id == ^id),
      set: [last_used_at: DateTime.utc_now(:second)]
    )
  end

  @doc "The token a client sends: sha256_hex(\"username:password\")."
  def token(username, password), do: hash("#{username}:#{password}")

  defp token_hash(username, password), do: hash(token(username, password))
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp generate_password, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  defp insert_audited(changeset, scope) do
    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, client} ->
          Audit.log(scope, :api_client, client.client_code, "API client registered", client.name)
          client

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  # Console bootstrap passes "System (bootstrap)" instead of a user scope.
  defp authorize(scope) when is_binary(scope), do: :ok
  defp authorize(scope), do: Policy.authorize(scope, :manage_api_clients)

  defp actor_id(%{user: %{id: id}}), do: id
  defp actor_id(_), do: nil
end
