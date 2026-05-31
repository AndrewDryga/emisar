defmodule Emisar.Audit.Event.Query do
  use Emisar, :query

  alias Emisar.Repo.Filter

  # Event types the audit log fires automatically as a byproduct of
  # normal traffic — one per dispatch (`policy.evaluated`) or per run
  # state transition (`action_run.*`). They're indispensable for
  # postmortem reconstruction but they bury the operator-facing events
  # (auth-key minted, member invited, approval decided) in the default
  # listing. The "Hide noisy events" filter excludes this set.
  @noisy_event_types ~w[
    policy.evaluated
    action_run.pending
    action_run.sent
    action_run.running
  ]

  def noisy_event_types, do: @noisy_event_types

  # The known set of event_type values, ordered by group. Drives the
  # filter dropdown so operators pick from a list instead of typing an
  # exact machine code from memory.
  @known_event_types [
    {"runner.connected", "Runner connected"},
    {"runner.disconnected", "Runner disconnected"},
    {"runner.disabled", "Runner disabled"},
    {"runner.deleted", "Runner deleted"},
    {"runner.error", "Runner error"},
    {"auth_key.created", "Auth key created"},
    {"auth_key.revoked", "Auth key revoked"},
    {"auth_key.bound", "Auth key bound to runner"},
    {"api_key.created", "API key created"},
    {"api_key.revoked", "API key revoked"},
    {"api_key.bound", "API key first use"},
    {"user.invited", "User invited"},
    {"user.password_reset_forced", "Password reset forced"},
    {"user.sessions_revoked", "User sessions revoked"},
    {"membership.suspended", "Member suspended"},
    {"membership.reinstated", "Member reinstated"},
    {"policy.updated", "Policy updated"},
    {"policy.evaluated", "Policy evaluated"},
    {"approval.approved", "Approval granted"},
    {"approval.denied", "Approval denied"},
    {"approval.expired", "Approval expired"},
    {"approval.grant_used", "Standing grant used"},
    {"approval.grant_revoked", "Standing grant revoked"},
    {"run.cancel_requested", "Run cancel requested"},
    {"action_run.pending", "Run queued"},
    {"action_run.sent", "Run sent to runner"},
    {"action_run.running", "Run started"},
    {"action_run.success", "Run succeeded"},
    {"action_run.failed", "Run failed"},
    {"action_run.error", "Run errored"},
    {"action_run.cancelled", "Run cancelled"},
    {"action_run.timed_out", "Run timed out"},
    {"action_run.denied", "Run denied by policy"},
    {"action_run.pending_approval", "Run awaiting approval"}
  ]

  def known_event_type_values, do: @known_event_types

  # Same set, grouped by the leading domain so a 34-item dropdown
  # becomes 7 small groups operators can scan instead of reading top
  # to bottom. The Filter UI renders these as <optgroup>s.
  @grouped_event_types [
    {"Runner",
     [
       {"runner.connected", "Connected"},
       {"runner.disconnected", "Disconnected"},
       {"runner.disabled", "Disabled"},
       {"runner.deleted", "Deleted"},
       {"runner.error", "Error"}
     ]},
    {"Auth key",
     [
       {"auth_key.created", "Created"},
       {"auth_key.revoked", "Revoked"},
       {"auth_key.bound", "Bound to runner"}
     ]},
    {"API key",
     [
       {"api_key.created", "Created"},
       {"api_key.revoked", "Revoked"},
       {"api_key.bound", "First use"}
     ]},
    {"User / team",
     [
       {"user.invited", "Invited"},
       {"user.password_reset_forced", "Password reset forced"},
       {"user.sessions_revoked", "Sessions revoked"},
       {"membership.suspended", "Suspended"},
       {"membership.reinstated", "Reinstated"}
     ]},
    {"Policy",
     [
       {"policy.updated", "Updated"},
       {"policy.evaluated", "Evaluated"}
     ]},
    {"Approval",
     [
       {"approval.approved", "Granted"},
       {"approval.denied", "Denied"},
       {"approval.expired", "Expired"},
       {"approval.grant_used", "Standing grant used"},
       {"approval.grant_revoked", "Standing grant revoked"}
     ]},
    {"Run",
     [
       {"run.cancel_requested", "Cancel requested"},
       {"action_run.pending", "Queued"},
       {"action_run.sent", "Sent to runner"},
       {"action_run.running", "Started"},
       {"action_run.success", "Succeeded"},
       {"action_run.failed", "Failed"},
       {"action_run.error", "Errored"},
       {"action_run.cancelled", "Cancelled"},
       {"action_run.timed_out", "Timed out"},
       {"action_run.denied", "Denied by policy"},
       {"action_run.pending_approval", "Awaiting approval"}
     ]}
  ]

  def grouped_event_type_values, do: @grouped_event_types

  def all,
    do: from(events in Emisar.Audit.Event, as: :events)

  def by_id(q, id),
    do: where(q, [events: e], e.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [events: e], e.account_id == ^account_id)

  def by_event_type(q, type),
    do: where(q, [events: e], e.event_type == ^type)

  def by_actor_kind(q, kind),
    do: where(q, [events: e], e.actor_kind == ^kind)

  def by_subject_kind(q, kind),
    do: where(q, [events: e], e.subject_kind == ^kind)

  def by_subject_id(q, id),
    do: where(q, [events: e], e.subject_id == ^id)

  def occurred_after(q, ts),
    do: where(q, [events: e], e.occurred_at > ^ts)

  def occurred_before(q, ts),
    do: where(q, [events: e], e.occurred_at < ^ts)

  def ordered_by_recent(q \\ all()),
    do: order_by(q, [events: e], desc: e.occurred_at)

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:events, :desc, :occurred_at}, {:events, :asc, :id}]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :event_type,
        title: "Type",
        type: {:list, :string},
        values: grouped_event_type_values(),
        fun: fn q, types -> {q, dynamic([events: e], e.event_type in ^types)} end
      },
      %Filter{
        name: :actor_kind,
        title: "Actor",
        type: {:list, :string},
        values: [
          {"user", "User"},
          {"api_key", "API key"},
          {"runner", "Runner"},
          {"system", "System"}
        ],
        fun: fn q, kinds -> {q, dynamic([events: e], e.actor_kind in ^kinds)} end
      },
      %Filter{
        name: :subject_kind,
        title: "Subject",
        type: {:list, :string},
        values: [
          {"runner", "Runner"},
          {"api_key", "API key"},
          {"auth_key", "Auth key"},
          {"action_run", "Action run"},
          {"approval_request", "Approval"}
        ],
        fun: fn q, kinds -> {q, dynamic([events: e], e.subject_kind in ^kinds)} end
      },
      %Filter{
        name: :hide_noise,
        title: "Hide run lifecycle",
        type: :boolean,
        fun: fn q, true ->
          {q, dynamic([events: e], e.event_type not in ^@noisy_event_types)}
        end
      }
    ]
end
