defmodule Emisar.Mailers.UserNotifier do
  @moduledoc """
  Transactional emails sent during user lifecycle: confirmation and
  magic-link login. Plain-text templates — the rendering engine is
  intentionally not LiveView's heex.
  """
  import Swoosh.Email
  alias Emisar.Mail
  alias Emisar.Mailer
  alias Emisar.PublicUrl
  alias Emisar.Users
  require Logger

  # Resolved at call-time (not compile-time) so `runtime.exs` env-var
  # overrides take effect without a recompile. Falls back to the
  # `config.exs` defaults for fork / dev environments.
  defp from do
    {Application.get_env(:emisar, :mailer_from_name, "emisar"),
     Application.get_env(:emisar, :mailer_from_email, "no-reply@emisar.dev")}
  end

  def deliver_confirmation_instructions(%Users.User{} = user, token) do
    url = PublicUrl.url("/confirm/#{token}")

    deliver(user.email, "Confirm your emisar account", """
    Welcome to emisar!

    Confirm your email to finish setting up your account:

    #{url}

    If you didn't sign up, you can safely ignore this email.

    — emisar
    """)
  end

  def deliver_magic_link(%Users.User{} = user, token_id, secret, return_to \\ nil) do
    url = PublicUrl.url("/sign_in/magic/#{token_id}/#{secret}#{return_to_query(return_to)}")

    deliver(user.email, "Your emisar sign-in code", """
    Your emisar sign-in code is:

        #{secret}

    Type it into the sign-in page in the browser where you requested it. On that
    same browser you can also just click:

    #{url}

    The code and link only sign in from the browser that made the request, so an
    intercepted email is useless on its own. They expire in 15 minutes and work
    once. Didn't request this? You can safely ignore it.

    — emisar
    """)
  end

  @doc """
  Notifies an approver that a run is waiting on their decision. The
  link lands on the approval detail page; the approver must be signed
  in to act (MFA-enforced accounts: same flow as direct nav).

  The body surfaces enough context — action, runner *name* (not the
  opaque id), the operator's reason, the matched policy rules, and a
  preview of the arguments — that an experienced operator can decide
  from their inbox without context-switching into the app.
  """
  def deliver_approval_request(%Users.User{} = approver, %{} = request, %{} = run) do
    url = PublicUrl.url("/app/approvals/#{request.id}")
    runner_label = runner_email_label(run)
    args_block = format_args_for_email(run)
    matched = format_matched_rules(run)

    body = """
    Hi #{approver.full_name || approver.email},

    A run is waiting on your decision:

      Action:    #{run.action_id}
      Runner:    #{runner_label}
      Reason:    #{request.reason || "(none)"}
      Policy:    #{run.policy_reason || "(none)"}#{matched}

    Arguments:
    #{args_block}

    Review and approve or deny:

      #{url}

    You'll need to sign in if you aren't already. Approvers are
    determined per workspace by the :decide_approval permission.

    — emisar
    """

    deliver(approver.email, "Approval needed: #{run.action_id}", body)
  end

  defp runner_email_label(%{runner: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp runner_email_label(%{runner_id: id}) when is_binary(id),
    do: "id #{String.slice(id, 0, 8)}…"

  defp runner_email_label(_), do: "(unknown runner)"

  defp format_matched_rules(%{matched_rules: rules}) when is_list(rules) and rules != [] do
    "\n  Matched:   " <> Enum.join(rules, ", ")
  end

  defp format_matched_rules(_), do: ""

  # Two-space indented args block. Approvers reading on a phone get a
  # readable preview; a long-tail of huge args still produces tidy
  # output because Jason's pretty-print already wraps reasonably.
  defp format_args_for_email(%{args: args}) when is_map(args) and map_size(args) > 0 do
    args
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp format_args_for_email(_), do: "  (none)"

  def deliver_account_invitation(%Users.User{} = invitee, %{} = inviter, account, token) do
    url = PublicUrl.url("/accept_invitation/#{token}")

    deliver(invitee.email, "You're invited to #{account.name} on emisar", """
    #{inviter.full_name || inviter.email} invited you to join the
    \"#{account.name}\" workspace on emisar.

    Accept the invite:

    #{url}

    What is emisar? It lets your AI safely run pre-approved operational
    actions on your infrastructure with full audit, policy, and approval
    workflows. https://emisar.dev
    """)
  end

  @doc """
  Welcomes a new workspace owner right after signup with their team's branded
  sign-in link, so they can hand it to the people they want to invite. Sent
  alongside — not instead of — the email-confirmation message.
  """
  def deliver_welcome(%Users.User{} = user, account) do
    url = PublicUrl.url("/app/#{account.slug}/sign_in")

    deliver(user.email, "Your emisar workspace is ready", """
    Welcome to emisar, #{user.full_name || user.email}!

    Your workspace "#{account.name}" is ready. You and your team sign in here:

    #{url}

    Share that link with the people you want on board — they'll sign in with
    their email, or through single sign-on once you connect it in
    Settings → SSO. (We've sent a separate email to confirm your address.)

    — emisar
    """)
  end

  # The branded sign-in pages thread a `/app/<slug>` return_to through these
  # links so the magic link / reset lands back on the right team. Already
  # whitelisted by `EmisarWeb.ReturnTo` at the call site; encoded for the URL here.
  defp return_to_query(nil), do: ""

  defp return_to_query(return_to) when is_binary(return_to),
    do: "?" <> URI.encode_query(return_to: return_to)

  defp deliver(to, subject, body) do
    if Mail.suppressed?(to) do
      # `to` hard-bounced or filed a spam complaint (recorded from the
      # Postmark webhook). Sending again only degrades sender reputation,
      # so skip it. The {:ok, _} shape keeps callers' success match intact.
      Logger.info("mail_suppressed recipient=#{redact_email(to)} subject=#{inspect(subject)}")
      {:ok, %{suppressed: true}}
    else
      new()
      |> to(to)
      |> from(from())
      |> subject(subject)
      |> text_body(body)
      |> Mailer.deliver()
    end
  end

  # Log recipients coarsely — first char + domain — so a suppression line
  # in the drain doesn't carry a full address.
  defp redact_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end
end
