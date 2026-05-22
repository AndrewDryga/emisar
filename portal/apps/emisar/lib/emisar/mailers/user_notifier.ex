defmodule Emisar.Mailers.UserNotifier do
  @moduledoc """
  Transactional emails sent during user lifecycle: confirmation,
  magic-link login, password reset. Plain-text templates — the
  rendering engine is intentionally not LiveView's heex.
  """

  import Swoosh.Email

  alias Emisar.Accounts.User
  alias Emisar.Mailer

  @from {"emisar", "no-reply@emisar.com"}

  def deliver_confirmation_instructions(%User{} = user, token) do
    url = url_for("/confirm/#{token}")

    deliver(user.email, "Confirm your emisar account", """
    Welcome to emisar!

    Confirm your email to finish setting up your account:

    #{url}

    If you didn't sign up, you can safely ignore this email.

    — emisar
    """)
  end

  def deliver_magic_link(%User{} = user, token) do
    url = url_for("/sign_in/magic/#{token}")

    deliver(user.email, "Your emisar magic link", """
    Click the link below to sign in to emisar. It expires in 15 minutes.

    #{url}

    Didn't request this? You can ignore it — nobody can sign in without
    clicking the link, and links can only be used once.
    """)
  end

  def deliver_password_reset(%User{} = user, token) do
    url = url_for("/reset_password/#{token}")

    deliver(user.email, "Reset your emisar password", """
    Reset your password using this link (valid for 1 hour):

    #{url}

    Didn't request a reset? You can ignore this email; your password
    won't change unless someone clicks the link.
    """)
  end

  @doc """
  Notifies an approver that a run is waiting on their decision. The
  link lands on the approval detail page; the approver must be signed
  in to act (MFA-enforced accounts: same flow as direct nav).
  """
  def deliver_approval_request(%User{} = approver, %{} = req, %{} = run) do
    url = url_for("/app/approvals/#{req.id}")

    deliver(approver.email, "Approval needed: #{run.action_id}", """
    Hi #{approver.full_name || approver.email},

    A run is waiting on your decision:

      Action:    #{run.action_id}
      Runner:    #{run.runner_id}
      Reason:    #{req.reason || "(none)"}
      Policy:    #{run.policy_reason || "(none)"}

    Review and approve or deny here:

      #{url}

    You'll need to sign in if you aren't already. Approvers are
    determined per workspace by the :decide_approval permission.

    — emisar
    """)
  end

  def deliver_account_invitation(%User{} = invitee, %{} = inviter, account, token) do
    url = url_for("/accept_invitation/#{token}")

    deliver(invitee.email, "You're invited to #{account.name} on emisar", """
    #{inviter.full_name || inviter.email} invited you to join the
    \"#{account.name}\" workspace on emisar.

    Accept the invite:

    #{url}

    What is emisar? It lets your AI safely run pre-approved operational
    actions on your infrastructure with full audit, policy, and approval
    workflows. https://emisar.com
    """)
  end

  defp deliver(to, subject, body) do
    new()
    |> to(to)
    |> from(@from)
    |> subject(subject)
    |> text_body(body)
    |> Mailer.deliver()
  end

  defp url_for(path) do
    base =
      Application.get_env(:emisar_web, EmisarWeb.Endpoint, [])
      |> Keyword.get(:url, [])
      |> case do
        [host: host, port: port] when is_integer(port) -> "https://#{host}:#{port}"
        [host: host] -> "https://#{host}"
        _ -> "http://localhost:4000"
      end

    base <> path
  end
end
