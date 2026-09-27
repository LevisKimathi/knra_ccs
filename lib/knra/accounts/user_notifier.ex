defmodule Knra.Accounts.UserNotifier do
  import Swoosh.Email

  alias Knra.Mailer
  alias Knra.Accounts.User

  @doc "Delivers a plain-text email using the application mailer."
  def deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(
        Application.get_env(:knra, :mail_from, {"KNRA Cargo Screening", "no-reply@knra.go.ke"})
      )
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account and log in by visiting the URL below:

    #{url}

    A KNRA Containerised Cargo Screening System account was created for you.
    After confirming, set a password under Settings.

    ==============================
    """)
  end
end
