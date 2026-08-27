defmodule Emisar.Audit.Authorizer do
  @moduledoc "Authorization for the audit log."
  use Emisar.Auth.Authorizer
  alias Emisar.Audit.Event

  def view_audit_permission, do: build(Event, :view)

  # The billing slice of the trail — the finance seat's whole audit reach.
  # Every full-trail role holds it TOO, even though `:view` already covers the
  # rows: `Permissions.covers_role?/2` is a plain subset test with no notion of
  # one permission implying another, so the implication has to be materialized
  # or an owner could no longer grant a role holding a permission they lack.
  def view_billing_audit_permission, do: build(Event, :view_billing)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin, :operator, :viewer],
    do: [view_audit_permission(), view_billing_audit_permission()]

  # The finance seat reads the money trail and nothing else. `for_subject/2`
  # below is what enforces that — the permission only opens the door.
  def list_permissions_for_role(:billing_manager),
    do: [view_billing_audit_permission()]

  # API clients can view audit; the controller gates the key KIND
  # (`:audit_export`) so only a log-shipping token — not an MCP key — reaches
  # `/api/audit`. The role-level permission only opens the door.
  def list_permissions_for_role(:api_client),
    do: [view_audit_permission(), view_billing_audit_permission()]

  def list_permissions_for_role(_), do: []

  @doc """
  The event types this subject's reads are narrowed to — `:all`, or the exact
  list nothing outside of can ever come back.

  The ONE judgment behind both halves of the trail: `for_subject/2` scopes the
  ROWS by it, and `Audit.event_filters/1` derives the OFFERED OPTIONS from it,
  so the panel cannot advertise a type the read withholds and the two cannot
  drift. Narrowing a role is one edit here.
  """
  def readable_event_types(%Subject{} = subject) do
    if has_permission?(subject, view_audit_permission()),
      do: :all,
      else: Event.Query.billing_event_types()
  end

  @impl Emisar.Auth.Authorizer
  # Row scoping is where the billing narrowing lives, so EVERY audit read — the
  # list, the detail fetch, the filter-option lookups, the export sweep — is
  # narrowed by construction. A crafted filter or a direct context call widens
  # nothing: this composes last, immediately before the `Repo` call (IL-4).
  def for_subject(queryable, %Subject{account: %{id: account_id}} = subject) do
    scoped = Event.Query.by_account_id(queryable, account_id)

    case readable_event_types(subject) do
      :all -> scoped
      types -> Event.Query.only_event_types(scoped, types)
    end
  end

  def for_subject(queryable, _), do: Event.Query.none(queryable)
end
