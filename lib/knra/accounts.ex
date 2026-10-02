defmodule Knra.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Knra.Repo

  alias Knra.Accounts.{User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password) and User.active?(user), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Staff administration (M1)

  alias Knra.Accounts.Policy
  alias Knra.Audit

  def list_users(filters \\ %{}) do
    User
    |> then(fn q ->
      case filters["q"] do
        v when v not in [nil, ""] ->
          where(q, [u], ilike(u.name, ^"%#{v}%") or ilike(u.email, ^"%#{v}%"))

        _ ->
          q
      end
    end)
    |> then(fn q ->
      case filters["role"] do
        v when v not in [nil, ""] -> where(q, [u], u.role == ^v)
        _ -> q
      end
    end)
    |> order_by([u], asc: u.status, asc: u.name)
    |> Repo.all()
  end

  @doc "Active users whose role grants `permission` (super admins always included)."
  def list_active_users_with_permission(permission) do
    keys = Knra.Accounts.Roles.keys_with_permission(permission)
    Repo.all(from u in User, where: u.role in ^keys and u.status == "active", order_by: u.name)
  end

  def list_active_users_by_role(role) do
    Repo.all(from u in User, where: u.role == ^role and u.status == "active", order_by: u.name)
  end

  def change_user_admin(%User{} = user, attrs \\ %{}) do
    User.admin_changeset(user, attrs, validate_unique: false)
  end

  @doc """
  Supervisor creates a staff account. The user receives an email link that
  confirms the account and logs them in; they then set a password.
  """
  def create_user(scope, attrs, magic_link_url_fun) do
    with :ok <- authorize_manage(scope, %User{}, requested_role(attrs)) do
      Repo.transact(fn ->
        with {:ok, user} <- %User{} |> User.admin_changeset(attrs) |> Repo.insert() do
          Audit.log(
            scope,
            :user,
            user.email,
            "Account created — #{User.role_label(user.role)}",
            user.station
          )

          {:ok, user}
        end
      end)
      |> tap(fn
        {:ok, user} -> deliver_login_instructions(user, magic_link_url_fun)
        _ -> :ok
      end)
    end
  end

  @doc "Supervisor edits name, role, staff number or duty station. A role change ends the user's sessions."
  def update_user(scope, %User{} = user, attrs) do
    with :ok <- authorize_manage(scope, user, requested_role(attrs)) do
      changeset = User.admin_changeset(user, attrs)

      Repo.transact(fn ->
        with {:ok, updated} <- Repo.update(changeset) do
          note =
            changeset.changes
            |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Map.get(user, k)} → #{v}" end)

          Audit.log(scope, :user, updated.email, "Account updated", note)

          tokens =
            if Map.has_key?(changeset.changes, :role) or Map.has_key?(changeset.changes, :email),
              do: expire_tokens(updated),
              else: []

          {:ok, {updated, tokens}}
        end
      end)
    end
  end

  @doc "Sets an account's status (active / suspended / deactivated). Suspending ends all sessions."
  def set_user_status(scope, %User{} = user, status, reason \\ nil) do
    with :ok <- authorize_manage(scope, user),
         :ok <- if(user.id == scope.user.id, do: {:error, :cannot_change_self}, else: :ok) do
      Repo.transact(fn ->
        with {:ok, updated} <- user |> User.status_changeset(status) |> Repo.update() do
          Audit.log(scope, :user, updated.email, "Account #{status}", reason)
          tokens = if status == "active", do: [], else: expire_tokens(updated)
          {:ok, {updated, tokens}}
        end
      end)
    end
  end

  @doc "Forces a password reset: clears the password, ends sessions and emails a login link."
  def force_password_reset(scope, %User{} = user, magic_link_url_fun) do
    with :ok <- authorize_manage(scope, user) do
      Repo.transact(fn ->
        updated = user |> Ecto.Changeset.change(hashed_password: nil) |> Repo.update!()
        Audit.log(scope, :user, user.email, "Password reset forced")
        {:ok, {updated, expire_tokens(updated)}}
      end)
      |> tap(fn
        {:ok, {u, _}} -> deliver_login_instructions(u, magic_link_url_fun)
        _ -> :ok
      end)
    end
  end

  # Supervisors manage staff; only super admins may touch super admin accounts.
  defp authorize_manage(scope, target, new_role \\ nil) do
    if Policy.manage_user?(scope, target, new_role), do: :ok, else: {:error, :unauthorized}
  end

  defp requested_role(attrs), do: attrs["role"] || attrs[:role]

  def touch_last_active(%User{id: id}) do
    Repo.update_all(from(u in User, where: u.id == ^id),
      set: [last_active_at: DateTime.utc_now(:second)]
    )
  end

  defp expire_tokens(user) do
    tokens = Repo.all_by(UserToken, user_id: user.id)
    Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
    tokens
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Knra.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Knra.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      {%User{status: "active"}, _} = found -> found
      _ -> nil
    end
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      {%User{status: status}, _token} when status != "active" ->
        {:error, :not_found}

      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{status: status}, _fun) when status != "active",
    do: {:error, :inactive}

  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
