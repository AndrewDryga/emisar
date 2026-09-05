defmodule Emisar.Audit.IdentityOption.Query do
  @moduledoc false
  use Emisar, :query
  alias Emisar.Audit.Event
  alias Emisar.Repo.Like

  # Historical labels deliberately include soft-deleted entities. Current user
  # names still belong to this account's surviving membership, not another tenant.
  def all(kind, side, account_id, readable_events) when side in [:actor, :target] do
    current = current_labels(kind, account_id)
    events = identity_events(readable_events, kind, side)
    logged = logged_labels(current, events, account_id)
    historical = historical_labels(current, events)

    logged |> union_all(^historical) |> options_query()
  end

  # The pinned selection is not part of the page: its cursor must never become
  # the boundary of a page it was not in. The actor's existing zero-event lookup
  # is intentional; a target needs readable event evidence even for its name.
  def selected(kind, side, account_id, readable_events, id) when side in [:actor, :target] do
    current = current_labels(kind, account_id)
    events = identity_events(readable_events, kind, side)
    events = where(events, [identity_events: e], e.id == ^id)
    current = where(current, [current_labels: c], c.id == ^id)

    labels =
      if side == :actor,
        do: current_options(current, account_id),
        else: logged_labels(current, events, account_id)

    named = labels |> union_all(^historical_labels(current, events)) |> options_query()

    fallback =
      from(e in subquery(events),
        as: :selected_event,
        limit: 1
      )

    named =
      select(named, [audit_identity_options: o], %{
        account_id: o.account_id,
        id: o.id,
        label: o.label,
        priority: 0
      })

    fallback =
      select(fallback, [selected_event: e], %{
        account_id: e.account_id,
        id: e.id,
        label: fragment("?::text", e.id),
        priority: 1
      })

    candidates = union_all(named, ^fallback)

    from(o in subquery(candidates),
      as: :audit_identity_options,
      order_by: o.priority,
      limit: 1,
      select: %{account_id: o.account_id, id: o.id, label: o.label}
    )
  end

  def by_account_id(queryable, account_id),
    do: where(queryable, [audit_identity_options: o], o.account_id == ^account_id)

  def none(queryable), do: where(queryable, false)
  def search(queryable, ""), do: queryable

  def search(queryable, term) do
    pattern = Like.contains(term)
    where(queryable, [audit_identity_options: o], ilike(o.label, ^pattern))
  end

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:audit_identity_options, :asc, :sort_label}, {:audit_identity_options, :asc, :id}]

  defp options_query(queryable) do
    sorted =
      from(o in subquery(queryable),
        as: :option_labels,
        select: %{
          account_id: o.account_id,
          id: o.id,
          label: o.label,
          sort_label: fragment("? COLLATE \"C\"", o.label)
        }
      )

    from(o in subquery(sorted), as: :audit_identity_options)
  end

  defp identity_events(queryable, kind, side) do
    {kind_field, id_field, label_field} = identity_fields(side)

    events =
      queryable
      |> where([events: e], field(e, ^kind_field) == ^kind and not is_nil(field(e, ^id_field)))
      |> select([events: e], %{
        account_id: e.account_id,
        id: field(e, ^id_field),
        label: field(e, ^label_field),
        occurred_at: e.occurred_at,
        event_id: e.id
      })

    from(e in subquery(events), as: :identity_events)
  end

  defp identity_fields(:actor), do: {:actor_kind, :actor_id, :actor_label}
  defp identity_fields(:target), do: {:target_kind, :target_id, :target_label}

  defp current_options(current, account_id) do
    current
    |> where([current_labels: c], not is_nil(c.label))
    |> select([current_labels: c], %{
      account_id: type(^account_id, Ecto.UUID),
      id: c.id,
      label: c.label
    })
  end

  defp logged_labels(current, events, account_id) do
    evidence = where(events, [identity_events: e], e.id == parent_as(:current_labels).id)
    current |> where(exists(subquery(evidence))) |> current_options(account_id)
  end

  defp historical_labels(current, events) do
    nonblank =
      where(
        events,
        [identity_events: e],
        not is_nil(e.label) and fragment("BTRIM(?) <> ''", e.label)
      )

    identities =
      nonblank
      |> distinct(true)
      |> select([identity_events: e], %{account_id: e.account_id, id: e.id})

    resolved =
      current
      |> where(
        [current_labels: c],
        c.id == parent_as(:historical_identity).id and not is_nil(c.label)
      )
      |> select([current_labels: c], c.id)

    unresolved =
      from(i in subquery(identities),
        as: :historical_identity,
        where: not exists(subquery(resolved))
      )

    # Choose the latest readable nonblank snapshot BEFORE searching it. An old
    # matching name must not displace the most recent label, nor may a hidden
    # billing-ineligible event supply a label to a billing-only reader. Deduplicate
    # IDs first so each unresolved identity needs only one chronological index
    # probe, rather than sorting all of its readable history on every search.
    latest =
      nonblank
      |> where([identity_events: e], e.id == parent_as(:historical_identity).id)
      |> order_by([identity_events: e], desc: e.occurred_at, desc: e.event_id)
      |> limit(1)
      |> select([identity_events: e], %{label: e.label})

    from(i in unresolved,
      inner_lateral_join: h in subquery(latest),
      as: :historical_labels,
      on: true,
      select: %{account_id: i.account_id, id: i.id, label: h.label}
    )
  end

  defp current_labels("user", account_id) do
    Emisar.Users.User.Query.all()
    |> Emisar.Users.User.Query.members_of_account(account_id)
    |> select([users: u, memberships: m], %{
      id: u.id,
      label:
        fragment(
          "COALESCE(NULLIF(BTRIM(?), ''), NULLIF(BTRIM(?), ''), ?::text)",
          m.directory_display_name,
          u.full_name,
          u.email
        )
    })
    |> wrap_labels()
  end

  defp current_labels("pack_version", account_id) do
    Emisar.Catalog.PackVersion.Query.all()
    |> Emisar.Catalog.PackVersion.Query.by_account_id(account_id)
    |> select([packs: p], %{id: p.id, label: fragment("? || '@' || ?", p.pack_id, p.version)})
    |> wrap_labels()
  end

  defp current_labels("policy", account_id) do
    Emisar.Policies.Policy.Query.all()
    |> Emisar.Policies.Policy.Query.by_account_id(account_id)
    |> select([policies: p], %{
      id: p.id,
      label:
        fragment(
          "CASE ? WHEN 'account' THEN 'Default policy' WHEN 'runner' THEN 'Runner policy · ' || ? WHEN 'group' THEN 'Group policy · ' || ? END",
          p.scope_type,
          p.scope_value,
          p.scope_value
        )
    })
    |> wrap_labels()
  end

  defp current_labels("approval_request", account_id) do
    Emisar.Approvals.Request.Query.all()
    |> Emisar.Approvals.Request.Query.by_account_id(account_id)
    |> select([requests: r], %{
      id: r.id,
      label:
        fragment(
          "CASE WHEN ?->>'kind' = 'runbook_execution' AND ?->'runbook' IS NOT NULL THEN CASE WHEN ?->>'execution_kind' = 'draft_test' THEN 'Draft test · ' || COALESCE(NULLIF(?->'runbook'->'title', 'false'::jsonb) #>> '{}', 'Runbook') ELSE COALESCE(NULLIF(?->'runbook'->'title', 'false'::jsonb) #>> '{}', 'Runbook execution') END ELSE ?->>'action_id' END",
          r.context,
          r.context,
          r.context,
          r.context,
          r.context,
          r.context
        )
    })
    |> wrap_labels()
  end

  defp current_labels(kind, account_id) do
    source =
      case kind do
        "runner" -> {Emisar.Runners.Runner.Query, :name}
        "api_key" -> {Emisar.ApiKeys.ApiKey.Query, :name}
        "enrollment_key" -> {Emisar.Runners.EnrollmentKey.Query, :description}
        "action_run" -> {Emisar.Runs.ActionRun.Query, :action_id}
        "runbook" -> {Emisar.Runbooks.Runbook.Query, :title}
        "approval_grant" -> {Emisar.Approvals.Grant.Query, :action_id}
        "identity_provider" -> {Emisar.SSO.IdentityProvider.Query, :name}
        _ -> nil
      end

    case source do
      {query_module, label_field} ->
        queryable = query_module.all() |> query_module.by_account_id(account_id)
        binding = queryable.from.as

        queryable
        |> select([{^binding, row}], %{id: row.id, label: field(row, ^label_field)})
        |> wrap_labels()

      nil ->
        Event.Query.all()
        |> Event.Query.none()
        |> select([events: e], %{id: e.id, label: fragment("NULL::text")})
        |> wrap_labels()
    end
  end

  defp wrap_labels(queryable), do: from(c in subquery(queryable), as: :current_labels)
end
