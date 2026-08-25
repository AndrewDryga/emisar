defmodule Emisar.Mailers.UserNotifier do
  @moduledoc """
  Transactional emails for account lifecycle, sign-in, profile security,
  invitations, and approvals. Short messages share the multipart frame in
  `Emisar.Mailers.Transactional`; the monthly report keeps its purpose-built
  renderer.

  **A paragraph is one line.** A mail client re-wraps a long line to its own
  window, but it can never undo a newline we sent, and an interpolated name or
  URL changes a line's rendered length — so a source-wrapped paragraph breaks
  at an arbitrary column on the recipient's screen. Newlines here are structure
  only: a blank line between blocks, a code or URL alone on its line, and
  indented `Label:` value blocks. `Emisar.Mailers.TextLayoutTest` holds the line.
  """
  import Swoosh.Email
  alias Emisar.Auth.Subject
  alias Emisar.Crypto
  alias Emisar.Mail
  alias Emisar.Mailer
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.Transactional
  alias Emisar.PublicUrl
  alias Emisar.RequestContext
  alias Emisar.Runs
  alias Emisar.Users
  require Logger

  # Resolved at call-time (not compile-time) so `runtime.exs` env-var
  # overrides take effect without a recompile. Falls back to the
  # `config.exs` defaults for fork / dev environments.
  defp from do
    {Application.get_env(:emisar, :mailer_from_name, "emisar"),
     Application.get_env(:emisar, :mailer_from_email, "no-reply@emisar.dev")}
  end

  def deliver_account_confirmation(
        %Users.User{} = user,
        token,
        account \\ nil,
        context \\ %RequestContext{}
      ) do
    url = PublicUrl.url("/confirm/#{token}")

    deliver_transactional(
      user,
      "Confirm your emisar email",
      "Confirm #{one_line(user.email)}. This link expires in 7 days.",
      [
        {:paragraph, "Confirm #{one_line(user.email)} to finish setting up your emisar sign-in."},
        {:facts, identity_facts(account, [{"Email", one_line(user.email)}])},
        {:section, "Request details"},
        {:pre, request_details(context)},
        {:paragraph, "This link works once and expires in 7 days."},
        {:paragraph, "If you didn't request this, ignore this email."}
      ],
      {"Confirm email address", url}
    )
  end

  def deliver_email_change_confirmation(
        %Users.User{} = user,
        token,
        account \\ nil,
        context \\ %RequestContext{}
      ) do
    url = PublicUrl.url("/confirm/#{token}")

    deliver_transactional(
      user,
      "Confirm your new sign-in email",
      "Confirm #{one_line(user.email)} before the link expires in 7 days.",
      [
        {:paragraph, "Confirm #{one_line(user.email)} as your new emisar sign-in email."},
        {:facts, identity_facts(account, [{"New email", one_line(user.email)}])},
        {:section, "Request details"},
        {:pre, request_details(context)},
        {:paragraph,
         "This link works once and expires in 7 days. Keep using your current email until you confirm the new one."},
        {:paragraph,
         "If you didn't request this change, don't use the link. Your sign-in email will stay the same."}
      ],
      {"Confirm new email", url}
    )
  end

  def deliver_magic_link(
        %Users.User{} = user,
        token_id,
        secret,
        context \\ %RequestContext{},
        return_to \\ nil,
        account \\ nil
      ) do
    url = PublicUrl.url("/sign_in/magic/#{token_id}/#{secret}#{return_to_query(return_to)}")

    deliver_transactional(
      user,
      "Your emisar sign-in code",
      "Your one-time sign-in code expires in 15 minutes.",
      [
        {:paragraph, sign_in_instruction(account)},
        {:code, secret},
        {:facts, identity_facts(account, [])},
        {:paragraph, "Enter the code in the browser where you asked to sign in."},
        {:paragraph, "It works once and expires in 15 minutes."},
        {:paragraph, "For security, the code only works in that browser."},
        {:section, "Request details"},
        {:pre, request_details(context)},
        {:paragraph, "If you didn't ask to sign in, ignore this email."}
      ],
      {"Sign in", url}
    )
  end

  # A small, human "who/when/where" block so the recipient can tell their own
  # sign-in from a stranger's. Time is always present; IP and a parsed
  # device summary are shown only when the request carried them. Two-space
  # indent and `Label:` keys are the same label/value grammar the approval
  # emails use, and the block is short enough to survive a `<pre>` on a phone.
  defp request_details(%RequestContext{} = context) do
    [
      {"Time", Calendar.strftime(DateTime.utc_now(), "%-d %b %Y at %H:%M UTC")},
      {"From", present(context.ip_address)},
      {"Device", device_summary(context.user_agent)}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map_join("\n", fn {label, value} ->
      "  #{String.pad_trailing("#{label}:", 8)}#{value}"
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

  def deliver_email_change_code(
        %Users.User{} = user,
        code,
        new_email,
        %RequestContext{} = context,
        account \\ nil
      ) do
    deliver_transactional(
      user,
      "Confirm your sign-in email change",
      "Use this code within 15 minutes to continue changing your sign-in email.",
      [
        {:paragraph, "Use this code to continue changing your emisar sign-in email."},
        {:code, code},
        {:facts, identity_facts(account, [{"New email", one_line(new_email)}])},
        {:section, "Request details"},
        {:pre, request_details(context)},
        {:paragraph, "This code works once and expires in 15 minutes."},
        {:paragraph,
         "If you didn't request this change, ignore the email. Your sign-in email will stay the same."}
      ]
    )
  end

  def deliver_mfa_enrollment_code(
        %Users.User{} = user,
        code,
        %RequestContext{} = context,
        account \\ nil
      ) do
    deliver_transactional(
      user,
      "Confirm authenticator setup",
      "Use this code within 15 minutes to continue adding an authenticator.",
      [
        {:paragraph, "Use this code to add an authenticator to your emisar sign-in."},
        {:code, code},
        {:facts, identity_facts(account, [])},
        {:section, "Request details"},
        {:pre, request_details(context)},
        {:paragraph, "This code works once and expires in 15 minutes."},
        {:paragraph,
         "If you didn't start this setup, ignore the email. Your authenticator settings will not change."}
      ]
    )
  end

  @doc """
  Notifies an approver that a run is waiting on their decision. The
  link lands on the approval detail page; the approver must be signed
  in to act (MFA-enforced accounts: same flow as direct nav).

  The body surfaces enough context — action, runner *name* (not the
  opaque id), the operator's reason, the matched policy rules, and a
  preview of the arguments — that an experienced operator can decide
  from their inbox without context-switching into the app.

  The recipient is the user actor on `subject`: the arguments are projected
  through `Runs.project_action_args/2`, so the mail shows exactly what that
  approver may see, with every declared sensitive value redacted.
  """
  def deliver_approval_request(
        %Subject{actor: %Users.User{} = approver} = subject,
        %{} = request,
        %Runs.ActionRun{} = run,
        requester_name \\ nil
      ) do
    url = approval_url(request)
    quorum = request_quorum(request)
    label = one_line(run.action_id)

    facts =
      [
        {"Account", account_fact(request.account)},
        {"Action", label},
        {"Runner", runner_email_label(run)},
        {"Requested by", one_line(requester_name || "Account member")},
        {"Channel", run_source_label(run.source)},
        {"Requested", format_datetime(Map.get(request, :requested_at))},
        {"Expires", format_datetime(Map.get(request, :expires_at))},
        {"Approvals", "0 of #{quorum}"},
        {"Requester can approve", requester_approval_label(request)},
        {"Why approval is needed",
         one_line(Map.get(run, :policy_reason) || "No reason recorded")},
        {"Matched rules", format_matched_rules(run)}
      ]
      |> present_facts()

    blocks =
      [
        {:status, "This action ", "needs your approval", ".", :warning},
        {:facts, facts}
      ]
      |> add_quoted_block("Request reason", Map.get(request, :reason))
      |> add_quoted_block("Evidence", Map.get(request, :evidence))
      |> add_quoted_block("Expected result", Map.get(request, :expected))
      |> Kernel.++([
        {:section, "Redacted arguments"},
        {:pre, format_args_for_email(run, subject)}
      ])

    deliver_transactional(
      approver,
      approval_subject(request, label),
      "Needs approval · 0 of #{quorum} approvals received.",
      blocks,
      {"Review approval", url},
      headers: approval_thread_headers(:requested, request, subject)
    )
  end

  @runbook_email_item_limit 12

  @doc """
  Notifies an approver about a whole runbook execution without assuming an
  ActionRun exists. The request context is the frozen, already-redacted plan.
  """
  def deliver_runbook_execution_approval_request(
        %Subject{actor: %Users.User{} = approver} = subject,
        %{} = request,
        requester_name \\ nil
      ) do
    plan = request.context["plan"] || %{}
    title = runbook_approval_title(request)
    stages = plan["stages"] || []
    total = plan["total_items"] || Enum.sum(Enum.map(stages, &length(&1["items"] || [])))
    quorum = request_quorum(request)

    blocks =
      [
        {:status, "This runbook ", "needs your approval", ".", :warning},
        {:facts,
         present_facts([
           {"Account", account_fact(request.account)},
           {"Runbook", one_line(title)},
           {"Requested by", one_line(requester_name || "Account member")},
           {"Stages", Integer.to_string(length(stages))},
           {"Actions", Integer.to_string(total)},
           {"Requested", format_datetime(Map.get(request, :requested_at))},
           {"Expires", format_datetime(Map.get(request, :expires_at))},
           {"Approvals", "0 of #{quorum}"},
           {"Requester can approve", requester_approval_label(request)}
         ])}
      ]
      |> add_quoted_block("Request reason", Map.get(request, :reason))
      |> Kernel.++([{:section, "Frozen execution plan"}, {:pre, format_execution_items(stages)}])

    deliver_transactional(
      approver,
      approval_subject(request, title),
      "Needs approval · 0 of #{quorum} approvals received.",
      blocks,
      {"Review approval", approval_url(request)},
      headers: approval_thread_headers(:requested, request, subject)
    )
  end

  @doc "Sends a self-contained approval lifecycle update in the recipient's request thread."
  def deliver_approval_event(
        %Subject{actor: %Users.User{} = approver} = subject,
        %{} = request,
        %{} = event
      ) do
    quorum = request_quorum(request)
    count = Map.get(event, :approved_count, 0)
    {preview, lead} = approval_event_copy(event, count, quorum)

    facts =
      [
        {"Account", account_fact(request.account)},
        {"Request", one_line(approval_decision_label(request))},
        {"Approvals", "#{count} of #{quorum}"},
        {"Updated by", one_line(Map.get(event, :actor_label))},
        {"Updated", format_datetime(Map.get(event, :occurred_at))}
      ]
      |> present_facts()

    blocks =
      [
        lead,
        {:facts, facts}
      ]
      |> add_quoted_block("Decision note", Map.get(event, :reason))

    deliver_transactional(
      approver,
      approval_subject(request, approval_decision_label(request)),
      preview,
      blocks,
      {"View current status", approval_url(request)},
      headers: approval_thread_headers(event, request, subject)
    )
  end

  @doc """
  Tells the operator who asked for a gated run how it was decided — approved,
  denied, or expired with nobody deciding.

  Deliberately carries no argument values. The approval page behind the link is
  the one surface that shows them, redacted and behind a sign-in; an email is
  forwarded, archived, and indexed, so a copy of the arguments here would put
  them somewhere the redaction rules can never reach.
  """
  def deliver_approval_decision(
        %Users.User{} = requester,
        %{} = request,
        approved_count \\ 0,
        event_kind \\ nil
      ) do
    label = approval_decision_label(request)
    quorum = request_quorum(request)

    {title, preview, lead} =
      requester_decision_copy(request.status, approved_count, quorum, event_kind)

    blocks =
      [
        lead,
        {:facts,
         present_facts([
           {"Account", account_fact(request.account)},
           {"Request", one_line(label)},
           {"Approvals", "#{approved_count} of #{quorum}"}
         ])}
      ]
      |> add_quoted_block("Request reason", Map.get(request, :reason))
      |> add_quoted_block("Decision note", Map.get(request, :decision_reason))

    deliver_transactional(
      requester,
      "#{title} · #{one_line(label)}",
      preview,
      blocks,
      {"View approval", approval_url(request)}
    )
  end

  defp runbook_approval_title(%{context: %{"execution_kind" => "draft_test"} = context}) do
    "Draft test · #{get_in(context, ["runbook", "title"]) || "runbook"}"
  end

  defp runbook_approval_title(request),
    do: get_in(request.context, ["runbook", "title"]) || "runbook execution"

  defp approval_decision_label(%{
         context: %{
           "execution_kind" => "draft_test",
           "runbook" => %{"title" => title}
         }
       })
       when is_binary(title),
       do: "Draft test · #{title}"

  defp approval_decision_label(%{context: %{"runbook" => %{"title" => title}}})
       when is_binary(title),
       do: title

  defp approval_decision_label(%{context: %{"action_id" => action_id}})
       when is_binary(action_id),
       do: action_id

  defp approval_decision_label(_request), do: "a gated run"

  defp runner_email_label(%{runner: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp runner_email_label(%{runner_id: id}) when is_binary(id),
    do: "id #{String.slice(id, 0, 8)}…"

  defp runner_email_label(_), do: "(unknown runner)"

  defp format_matched_rules(%{matched_rules: rules}) when is_list(rules) and rules != [],
    do: Enum.map_join(rules, ", ", &one_line/1)

  defp format_matched_rules(_), do: nil

  # Two-space indented args block. Approvers reading on a phone get a
  # readable preview; a long-tail of huge args still produces tidy
  # output because Jason's pretty-print already wraps reasonably. A run whose
  # stored payload won't project says so rather than guessing at content — the
  # approval page is the fallback, and a mail can't ask for a second opinion.
  defp format_args_for_email(%Runs.ActionRun{} = run, %Subject{} = subject) do
    case Runs.project_action_args(run, subject) do
      {:ok, args} when map_size(args) > 0 -> indented_args(args)
      {:ok, _empty} -> "  (none)"
      {:error, _reason} -> "  (unavailable)"
    end
  end

  defp indented_args(args) do
    Jason.encode!(args, pretty: true)
  end

  defp format_execution_items([]), do: "  (no items)"

  defp format_execution_items(stages) when is_list(stages) do
    items =
      Enum.flat_map(stages, fn stage ->
        Enum.map(stage["items"] || [], &{stage["title"] || stage["id"] || "Stage", &1})
      end)

    shown = Enum.take(items, @runbook_email_item_limit)

    lines =
      Enum.map_join(shown, "\n", fn {stage, item} ->
        action = item["action"] || "(unknown action)"
        runner = item["runner_ref"] || "(unknown runner)"
        risk = item["risk"] || "unknown"
        args = Jason.encode!(item["args"] || %{})

        "• #{one_line(stage)}: #{one_line(action)} on #{one_line(runner)}\n  Risk: #{one_line(risk)}\n  Redacted arguments: #{args}"
      end)

    remaining = length(items) - length(shown)

    if remaining > 0 do
      lines <> "\n• … and #{remaining} more #{if remaining == 1, do: "item", else: "items"}"
    else
      lines
    end
  end

  def deliver_account_invitation(
        %Users.User{} = invitee,
        %{} = inviter,
        account,
        membership,
        token
      ) do
    url = PublicUrl.url("/accept_invitation/#{token}")
    inviter_name = one_line(inviter.full_name || inviter.email)
    account_name = one_line(account.name)

    deliver_transactional(
      invitee,
      "Join #{account_name} on emisar",
      "#{inviter_name} invited you to join #{account_name}. The invitation expires in 7 days.",
      [
        {:paragraph, "#{inviter_name} invited you to join #{account_name} on emisar."},
        {:facts,
         [
           {"Account", account_fact(account)},
           {"Role", Emisar.Auth.role_label(membership.role)},
           {"Runner access", invitation_runner_access(membership)},
           {"Pack access", invitation_pack_access(membership)},
           {"Invitation expires", invitation_expiry(membership)}
         ]},
        {:paragraph,
         "If you weren't expecting this invitation, ignore it. You will not join the account unless you accept."}
      ],
      {"Accept invitation", url}
    )
  end

  defp invitation_runner_access(%{runner_access_mode: :all}), do: "All runners"
  defp invitation_runner_access(%{runner_access_mode: :restricted}), do: "Selected runners"
  defp invitation_runner_access(_membership), do: "No runners"

  defp invitation_pack_access(%{pack_access_mode: :all}), do: "All packs"
  defp invitation_pack_access(%{pack_access_mode: :restricted}), do: "Selected packs"
  defp invitation_pack_access(_membership), do: "No packs"

  defp invitation_expiry(%{inserted_at: %DateTime{} = inserted_at}) do
    inserted_at |> DateTime.add(7, :day) |> format_datetime()
  end

  defp invitation_expiry(_membership), do: "7 days after it was sent"

  defp approval_url(request),
    do: PublicUrl.url("/app/#{request.account.slug}/approvals/#{request.id}")

  defp approval_subject(request, label) do
    "[#{account_name(request.account)}] Approval · #{one_line(label)} · #{short_id(request.id)}"
    |> String.slice(0, 180)
  end

  defp account_name(%{name: name}) when is_binary(name), do: one_line(name)
  defp account_name(%{account_name: name}) when is_binary(name), do: one_line(name)
  defp account_name(%{slug: slug}) when is_binary(slug), do: one_line(slug)
  defp account_name(_account), do: "Account"

  defp account_fact(%{slug: slug} = account) when is_binary(slug) do
    {:link, account_name(account), PublicUrl.url("/app/#{slug}")}
  end

  defp account_fact(account), do: account_name(account)

  defp identity_facts(nil, facts), do: present_facts(facts)

  defp identity_facts(account, facts) do
    present_facts([{"Requested from", account_fact(account)} | facts])
  end

  defp sign_in_instruction(nil), do: "Use this code to sign in to emisar."

  defp sign_in_instruction(account),
    do: "Use this code to sign in to #{account_name(account)} on emisar."

  defp short_id(id) do
    id
    |> safe_message_part()
    |> String.replace(["-", "."], "")
    |> String.slice(0, 8)
    |> String.upcase()
  end

  defp approval_thread_headers(:requested, request, %Subject{} = subject) do
    [
      {"Message-ID", approval_root_message_id(request, subject)},
      {"X-PM-KeepID", "true"}
    ]
  end

  defp approval_thread_headers(event, request, %Subject{} = subject) when is_map(event) do
    root = approval_root_message_id(request, subject)
    event_id = Map.get(event, :id) || Map.get(event, :decision_id) || request.id
    kind = event |> Map.fetch!(:kind) |> Atom.to_string()

    [
      {"Message-ID",
       "<approval.#{safe_message_part(kind)}.#{safe_message_part(event_id)}.#{safe_message_part(subject.membership_id)}@emisar.dev>"},
      {"In-Reply-To", root},
      {"References", root},
      {"X-PM-KeepID", "true"}
    ]
  end

  defp approval_root_message_id(request, %Subject{} = subject) do
    "<approval.request.#{safe_message_part(request.id)}.#{safe_message_part(subject.membership_id)}@emisar.dev>"
  end

  defp safe_message_part(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/u, "-")
    |> String.slice(0, 100)
  end

  defp request_quorum(%{min_approvals: value}) when is_integer(value) and value > 0, do: value
  defp request_quorum(_request), do: 1

  defp requester_approval_label(%{allow_self_approval: false}), do: "No"
  defp requester_approval_label(%{allow_self_approval: true}), do: "Yes"
  defp requester_approval_label(_request), do: nil

  defp run_source_label(:mcp), do: "MCP"
  defp run_source_label(:runbook), do: "Runbook"
  defp run_source_label(_source), do: "Portal"

  defp approval_event_copy(%{kind: :vote} = event, count, quorum) do
    actor = one_line(Map.get(event, :actor_label) || "An approver")

    {
      "#{actor} approved · #{count} of #{quorum} approvals received.",
      {:status, "#{actor} ", "approved",
       " this request. #{count} of #{quorum} approvals received.", :success}
    }
  end

  defp approval_event_copy(%{kind: :approved}, count, quorum) do
    {
      "Approved · #{count} of #{quorum} approvals received.",
      {:status, "This approval request was ", "approved",
       " with #{count} of #{quorum} approvals.", :success}
    }
  end

  defp approval_event_copy(%{kind: :denied} = event, count, quorum) do
    actor = one_line(Map.get(event, :actor_label) || "An approver")

    {
      "#{actor} denied the request.",
      {:status, "This approval request was ", "denied",
       " by #{actor} with #{count} of #{quorum} approvals.", :danger}
    }
  end

  defp approval_event_copy(%{kind: :expired}, count, quorum) do
    {
      "Approval expired · #{count} of #{quorum} approvals received.",
      {:status, "This approval request ", "expired", " with #{count} of #{quorum} approvals.",
       :warning}
    }
  end

  defp approval_event_copy(%{kind: :cancelled}, count, quorum) do
    {
      "Approval cancelled · #{count} of #{quorum} approvals received.",
      {:status, "This approval request was ", "cancelled",
       " with #{count} of #{quorum} approvals.", :warning}
    }
  end

  defp approval_event_copy(%{kind: :overridden} = event, count, quorum) do
    actor = one_line(Map.get(event, :actor_label) || "An owner or admin")

    {
      "#{actor} used an emergency override.",
      {:status, "#{actor} used an ", "emergency override",
       " after #{count} of #{quorum} approvals.", :warning}
    }
  end

  defp requester_decision_copy(:approved, count, quorum, :overridden) do
    {
      "Approval override used",
      "An owner or admin used an emergency override.",
      {:status, "An owner or admin used an ", "emergency override",
       " after #{count} of #{quorum} approvals.", :warning}
    }
  end

  defp requester_decision_copy(:approved, count, quorum, _event_kind) do
    {
      "Approval complete",
      "Your approval request was approved.",
      {:status, "Your approval request was ", "approved",
       " with #{count} of #{quorum} approvals.", :success}
    }
  end

  defp requester_decision_copy(:denied, count, quorum, _event_kind) do
    {
      "Approval denied",
      "Your approval request was denied.",
      {:status, "Your approval request was ", "denied", " with #{count} of #{quorum} approvals.",
       :danger}
    }
  end

  defp requester_decision_copy(:expired, count, quorum, _event_kind) do
    {
      "Approval expired",
      "Your approval request expired.",
      {:status, "Your approval request ", "expired", " with #{count} of #{quorum} approvals.",
       :warning}
    }
  end

  defp requester_decision_copy(:cancelled, count, quorum, _event_kind) do
    {
      "Approval cancelled",
      "Your approval request was cancelled.",
      {:status, "Your approval request was ", "cancelled",
       " with #{count} of #{quorum} approvals.", :warning}
    }
  end

  defp add_quoted_block(blocks, _title, nil), do: blocks
  defp add_quoted_block(blocks, _title, ""), do: blocks

  defp add_quoted_block(blocks, title, value) when is_binary(value) do
    blocks ++ [{:section, title}, {:pre, quoted(value)}]
  end

  defp quoted(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
    |> String.slice(0, 4_000)
  end

  defp present_facts(facts) do
    facts
    |> Enum.reject(fn {_label, value} -> is_nil(value) or value == "" end)
    |> Enum.map(fn {label, value} -> {one_line(label), present_fact_value(value)} end)
  end

  defp present_fact_value({:link, label, url}),
    do: {:link, one_line(label), one_line(url)}

  defp present_fact_value(value), do: one_line(value)

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%-d %b %Y at %H:%M UTC")

  defp format_datetime(_datetime), do: nil

  defp one_line(nil), do: nil

  defp one_line(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end

  @doc """
  Monthly account-health value report — a plain, honest summary of the prior
  calendar month: runs executed, approvals that gated risky work, and current
  posture, with deep links back into the console. The report job only calls this
  for accounts with real usage in the window, so there's no empty "you did
  nothing" copy to write. `Emisar.Mailers.MonthlyReport` renders both bodies.
  """
  def deliver_monthly_account_report(%Users.User{} = recipient, account, report) do
    unsubscribe_url =
      PublicUrl.url(
        "/unsubscribe/monthly-report/#{Crypto.monthly_report_unsubscribe_token(account.id)}"
      )

    rendered = MonthlyReport.render(recipient, account, report, unsubscribe_url)

    deliver(recipient.email, rendered.subject, rendered.text,
      html_body: rendered.html,
      reply_to: "support@emisar.dev",
      headers: [
        {"List-Unsubscribe", "<#{unsubscribe_url}>"},
        {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"}
      ]
    )
  end

  # The branded sign-in pages thread a `/app/<slug>` return_to through these
  # links so the magic link / reset lands back on the right team. Already
  # whitelisted by `EmisarWeb.ReturnTo` at the call site; encoded for the URL here.
  defp return_to_query(nil), do: ""

  defp return_to_query(return_to) when is_binary(return_to),
    do: "?" <> URI.encode_query(return_to: return_to)

  defp deliver_transactional(recipient, subject, preview, blocks),
    do: deliver_transactional(recipient, subject, preview, blocks, nil, [])

  defp deliver_transactional(recipient, subject, preview, blocks, action),
    do: deliver_transactional(recipient, subject, preview, blocks, action, [])

  defp deliver_transactional(
         %Users.User{} = recipient,
         subject,
         preview,
         blocks,
         action,
         opts
       ) do
    rendered =
      Transactional.render(%{
        recipient: one_line(recipient.full_name || recipient.email),
        title: one_line(subject),
        preview: one_line(preview),
        blocks: blocks,
        action: action,
        footer: Keyword.get(opts, :footer)
      })

    deliver(recipient.email, one_line(subject), rendered.text,
      html_body: rendered.html,
      reply_to: "support@emisar.dev",
      headers: Keyword.get(opts, :headers, [])
    )
  end

  defp deliver(to, subject, body, opts) do
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
      |> maybe_reply_to(Keyword.get(opts, :reply_to))
      |> subject(subject)
      |> text_body(body)
      |> maybe_html_body(Keyword.get(opts, :html_body))
      |> put_extra_headers(Keyword.get(opts, :headers, []))
      |> put_provider_option(:track_opens, false)
      |> put_provider_option(:track_links, "None")
      |> Mailer.deliver()
    end
  end

  defp maybe_reply_to(email, nil), do: email
  defp maybe_reply_to(email, address) when is_binary(address), do: reply_to(email, address)

  defp maybe_html_body(email, nil), do: email
  defp maybe_html_body(email, body) when is_binary(body), do: html_body(email, body)

  defp put_extra_headers(email, headers),
    do: Enum.reduce(headers, email, fn {key, value}, acc -> header(acc, key, value) end)

  # Log recipients coarsely — first char + domain — so a suppression line
  # in the drain doesn't carry a full address.
  defp redact_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end
end
