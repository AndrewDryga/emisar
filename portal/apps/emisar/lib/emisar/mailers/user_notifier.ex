defmodule Emisar.Mailers.UserNotifier do
  @moduledoc """
  Transactional emails for account lifecycle, sign-in, profile security,
  invitations, and approvals. Plain-text templates -- the rendering engine is
  intentionally not LiveView's heex.
  """
  import Swoosh.Email
  alias Emisar.Mail
  alias Emisar.Mailer
  alias Emisar.PublicUrl
  alias Emisar.RequestContext
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
    sign_in_url = PublicUrl.url("/sign_in")

    deliver(user.email, "Confirm your emisar account", """
    Welcome to emisar!

    Confirm your email to finish setting up your account:

    #{url}

    You can sign in any time — emisar emails you a one-time link, no password
    to set:

    #{sign_in_url}

    If you didn't sign up, you can safely ignore this email.

    — emisar
    """)
  end

  def deliver_magic_link(
        %Users.User{} = user,
        token_id,
        secret,
        context \\ %RequestContext{},
        return_to \\ nil
      ) do
    url = PublicUrl.url("/sign_in/magic/#{token_id}/#{secret}#{return_to_query(return_to)}")

    deliver(user.email, "Your emisar sign-in code", """
    Your emisar sign-in code is:

        #{secret}

    Type it into the sign-in page in the browser where you asked to sign in. From
    that same browser you can also just open:

    #{url}

    This code only works in the browser that requested it, works once, and expires
    in 15 minutes — an intercepted email can't sign in on its own.

    This sign-in was requested:

    #{request_details(context)}

    Didn't ask to sign in? You can ignore this email — nothing happens without the
    code, and it only works in the browser that made the request. If sign-in
    emails you didn't ask for keep arriving, tell your administrator.

    — emisar
    """)
  end

  # A small, human "who/when/where" block so the recipient can tell their own
  # sign-in from a stranger's. Time is always present; IP and a parsed
  # device summary are shown only when the request carried them.
  defp request_details(%RequestContext{} = context) do
    [
      {"Time", Calendar.strftime(DateTime.utc_now(), "%-d %b %Y at %H:%M UTC")},
      {"From", present(context.ip_address)},
      {"Device", device_summary(context.user_agent)}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map_join("\n", fn {label, value} ->
      "      #{String.pad_trailing(label, 8)} #{value}"
    end)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  # Best-effort "Chrome on macOS" from a User-Agent — friendlier than the raw
  # string, and omitted entirely (nil) when we can't read either half. Order
  # matters: Edge/Opera UAs also contain "Chrome", and Chrome's contains "Safari".
  defp device_summary(ua) when is_binary(ua) and ua != "" do
    browser =
      cond do
        String.contains?(ua, "Edg/") -> "Edge"
        String.contains?(ua, "OPR/") or String.contains?(ua, "Opera") -> "Opera"
        String.contains?(ua, "Firefox/") -> "Firefox"
        String.contains?(ua, "Chrome/") -> "Chrome"
        String.contains?(ua, "Safari/") -> "Safari"
        true -> nil
      end

    os =
      cond do
        String.contains?(ua, "iPhone") -> "iOS"
        String.contains?(ua, "iPad") -> "iPadOS"
        String.contains?(ua, "Android") -> "Android"
        String.contains?(ua, "Mac OS X") or String.contains?(ua, "Macintosh") -> "macOS"
        String.contains?(ua, "Windows") -> "Windows"
        String.contains?(ua, "Linux") -> "Linux"
        true -> nil
      end

    case {browser, os} do
      {nil, nil} -> nil
      {browser, nil} -> browser
      {nil, os} -> os
      {browser, os} -> "#{browser} on #{os}"
    end
  end

  defp device_summary(_), do: nil

  def deliver_email_change_code(%Users.User{} = user, code) do
    deliver(user.email, "Confirm your emisar email change", """
    Someone asked to change the email address on your emisar account.

    To confirm the change, enter this code on the email-change form:

        #{code}

    The code works once and expires in 15 minutes. If you didn't request this,
    you can safely ignore this email — your address is unchanged, and whoever
    asked can't proceed without this code sent here.

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
    # Canonical console route is /app/:account/approvals/:id — a slug-less
    # link 404s, so the request must arrive with its account preloaded.
    url = PublicUrl.url("/app/#{request.account.slug}/approvals/#{request.id}")
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
    sign_in_url = PublicUrl.url("/app/#{account.slug}/sign_in")

    deliver(invitee.email, "You're invited to #{account.name} on emisar", """
    #{inviter.full_name || inviter.email} invited you to join the
    \"#{account.name}\" workspace on emisar.

    Accept the invite:

    #{url}

    After you accept, this is where you sign in to #{account.name} — emisar
    emails you a one-time link, so there's no password to set:

    #{sign_in_url}

    What is emisar? It lets your AI safely run pre-approved operational
    actions on your infrastructure with full audit, policy, and approval
    workflows. https://emisar.dev
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
