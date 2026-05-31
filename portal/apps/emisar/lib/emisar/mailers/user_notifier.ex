defmodule Emisar.Mailers.UserNotifier do
  @moduledoc """
  Transactional emails sent during user lifecycle: confirmation,
  magic-link login, password reset. Plain-text templates — the
  rendering engine is intentionally not LiveView's heex.
  """

  import Swoosh.Email

  alias Emisar.Accounts.User
  alias Emisar.Mailer

  @from {"emisar", "no-reply@emisar.dev"}

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

  The body surfaces enough context — action, runner *name* (not the
  opaque id), the operator's reason, the matched policy rules, and a
  preview of the arguments — that an experienced operator can decide
  from their inbox without context-switching into the app.
  """
  def deliver_approval_request(%User{} = approver, %{} = req, %{} = run) do
    url = url_for("/app/approvals/#{req.id}")
    runner_label = runner_email_label(run)
    args_block = format_args_for_email(run)
    matched = format_matched_rules(run)

    body = """
    Hi #{approver.full_name || approver.email},

    A run is waiting on your decision:

      Action:    #{run.action_id}
      Runner:    #{runner_label}
      Reason:    #{req.reason || "(none)"}
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
    |> Enum.map_join("\n", fn line -> "  " <> line end)
  end

  defp format_args_for_email(_), do: "  (none)"

  def deliver_account_invitation(%User{} = invitee, %{} = inviter, account, token) do
    url = url_for("/accept_invitation/#{token}")

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

  defp deliver(to, subject, body) do
    new()
    |> to(to)
    |> from(@from)
    |> subject(subject)
    |> text_body(body)
    |> Mailer.deliver()
  end

  # Builds an absolute URL the mailer can stick in an email body.
  # Honors the endpoint's configured scheme (so dev emails use `http://`
  # and don't 404 with cert errors against localhost:4000), host, and
  # port. Falls back to the dev URL only when no endpoint config exists.
  defp url_for(path) do
    url_cfg = Application.get_env(:emisar_web, EmisarWeb.Endpoint, []) |> Keyword.get(:url, [])
    host = Keyword.get(url_cfg, :host)
    scheme = Keyword.get(url_cfg, :scheme, "https")
    port = Keyword.get(url_cfg, :port)

    base =
      cond do
        is_binary(host) and is_integer(port) and not default_port?(scheme, port) ->
          "#{scheme}://#{host}:#{port}"

        is_binary(host) ->
          "#{scheme}://#{host}"

        true ->
          "http://localhost:4000"
      end

    base <> path
  end

  defp default_port?("https", 443), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_, _), do: false
end
