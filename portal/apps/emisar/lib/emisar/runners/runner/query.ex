defmodule Emisar.Runners.Runner.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(runners in Emisar.Runners.Runner, as: :runners)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.deleted_at))

  def not_disabled(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.disabled_at))

  def none(queryable), do: where(queryable, false)

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  def by_id(queryable, id),
    do: where(queryable, [runners: r], r.id == ^id)

  def by_connection_lease(queryable, generation, lease_id) do
    where(
      queryable,
      [runners: r],
      r.connection_generation == ^generation and r.connection_lease_id == ^lease_id
    )
  end

  def lease_available(queryable, now) do
    where(
      queryable,
      [runners: r],
      is_nil(r.connection_lease_id) or is_nil(r.connection_lease_expires_at) or
        r.connection_lease_expires_at <= ^now
    )
  end

  def by_ids(queryable, ids),
    do: where(queryable, [runners: r], r.id in ^ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runners: r], r.account_id == ^account_id)

  def select_scope_facts(queryable),
    do: select(queryable, [runners: r], %{id: r.id, group: r.group})

  @doc "Selects `{runner_id, runner_name}` for account-scoped UI option lists."
  def select_options(queryable),
    do: select(queryable, [runners: r], {r.id, r.name})

  @doc """
  The distinct group names the matched runners carry — the existence half of a
  runner-scope allowlist, so a selection can be checked against a group without
  reading the rows in it.
  """
  def select_distinct_groups(queryable),
    do: queryable |> distinct(true) |> select([runners: r], r.group)

  # The durable pack advertisement a runner last sent, plus the identity the
  # console names it by. `packs` is the whole runner_state map, so a pack that
  # advertises no actions still counts as installed.
  def select_pack_advertisement_facts(queryable),
    do: select(queryable, [runners: r], %{id: r.id, name: r.name, group: r.group, packs: r.packs})

  def with_active_account(queryable) do
    join(
      queryable,
      :inner,
      [runners: r],
      account in ^Emisar.Accounts.Account.Query.active(),
      on: r.account_id == account.id,
      as: :account
    )
  end

  def by_bootstrap_enrollment_key_id(queryable, enrollment_key_id),
    do: where(queryable, [runners: r], r.bootstrap_enrollment_key_id == ^enrollment_key_id)

  def by_external_id(queryable, external_id),
    do: where(queryable, [runners: r], r.external_id == ^external_id)

  def by_name(queryable, name),
    do: where(queryable, [runners: r], r.name == ^name)

  def by_group(queryable, group),
    do: where(queryable, [runners: r], r.group == ^group)

  def by_groups(queryable, groups) when is_list(groups),
    do: where(queryable, [runners: r], r.group in ^groups)

  def enforcing(queryable \\ all()),
    do: where(queryable, [runners: r], r.enforce_signatures == true)

  @doc """
  Restrict to the runners a per-membership scope set grants — matched by
  runner id (`runner_ids`) or by group (`groups`). Drives query-level runner
  ACLs; the caller handles the empty-scopes-means-all case before calling.
  """
  def by_scope_values(queryable, runner_ids, groups),
    do: where(queryable, [runners: r], r.id in ^runner_ids or r.group in ^groups)

  def ordered_by_group_name(queryable),
    do: order_by(queryable, [runners: r], asc: r.group, asc: r.name)

  def ordered_by_name(queryable),
    do: order_by(queryable, [runners: r], asc: r.name, asc: r.id)

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  @doc """
  Filter by derived connection state. `online_ids` is the set of runner
  ids currently tracked in `Emisar.Runners.Presence` — the DB can't see
  presence, so the context resolves the ids and hands them in. `statuses`
  is any of `"connected"`, `"disconnected"`, `"pending"`, `"disabled"`,
  ORed together. An empty `statuses` list matches nothing.
  """
  def by_connection(queryable \\ all(), statuses, online_ids) when is_list(statuses) do
    # Clauses mirror `Emisar.Runners.connection_state/1`'s precedence
    # (disabled beats a stale socket), so the four states partition the
    # set cleanly — a disabled-never-connected runner is only "disabled".
    condition =
      Enum.reduce(statuses, dynamic(false), fn
        "connected", acc ->
          dynamic([runners: r], ^acc or (r.id in ^online_ids and is_nil(r.disabled_at)))

        "disconnected", acc ->
          dynamic(
            [runners: r],
            ^acc or
              (r.id not in ^online_ids and not is_nil(r.last_connected_at) and
                 is_nil(r.disabled_at))
          )

        "pending", acc ->
          dynamic(
            [runners: r],
            ^acc or
              (is_nil(r.last_connected_at) and r.id not in ^online_ids and is_nil(r.disabled_at))
          )

        "disabled", acc ->
          dynamic([runners: r], ^acc or not is_nil(r.disabled_at))

        _other, acc ->
          acc
      end)

    where(queryable, ^condition)
  end

  @doc """
  One-row fleet aggregate — the whole scoped fleet's posture without
  materializing a single runner. Presence supplies both id sets the DB can't
  see: `online_ids` is every runner with a live socket, `stale_ids` the subset
  whose last heartbeat has aged out. Clauses mirror
  `Emisar.Runners.connection_state/1`'s precedence (disabled beats a live
  socket), and posture counts exclude disabled runners — a parked runner's
  signature/degradation posture isn't actionable. `offline`, `active`, and the
  remaining portal-dispatch states are arithmetic over these, so the context
  derives them.
  """
  def fleet_status(queryable, online_ids, stale_ids) do
    select(queryable, [runners: r], %{
      total: count(r.id),
      disabled: filter(count(r.id), not is_nil(r.disabled_at)),
      online: filter(count(r.id), r.id in ^online_ids and is_nil(r.disabled_at)),
      pending:
        filter(
          count(r.id),
          is_nil(r.last_connected_at) and r.id not in ^online_ids and is_nil(r.disabled_at)
        ),
      stale: filter(count(r.id), r.id in ^stale_ids and is_nil(r.disabled_at)),
      signed_only: filter(count(r.id), r.enforce_signatures == true and is_nil(r.disabled_at)),
      degraded:
        filter(
          count(r.id),
          fragment("cardinality(?)", r.degraded_packs) > 0 and is_nil(r.disabled_at)
        ),
      degraded_packs:
        coalesce(
          filter(sum(fragment("cardinality(?)", r.degraded_packs)), is_nil(r.disabled_at)),
          0
        ),
      portal_ready:
        filter(
          count(r.id),
          r.id in ^online_ids and r.enforce_signatures == false and is_nil(r.disabled_at)
        )
    })
  end

  @doc """
  The fleet-wide connection tally as ONE pass, mirroring the `connected/1`,
  `disconnected/1`, `never_connected/1`, and `disabled/1` predicates. Those
  four states are disjoint over live rows, so counting them as four separate
  aggregates scanned `runners` four times for one telemetry sample.

  The caller supplies the not-deleted scope; disabled is counted across it
  while the other three exclude disabled rows, exactly as the separate
  queries did (`disabled` beats a live socket, per `connection_state/1`).
  """
  def connection_counts(queryable \\ not_deleted()) do
    select(queryable, [runners: r], %{
      disabled: filter(count(r.id), not is_nil(r.disabled_at)),
      never_connected: filter(count(r.id), is_nil(r.last_connected_at) and is_nil(r.disabled_at)),
      connected:
        filter(
          count(r.id),
          not is_nil(r.last_connected_at) and
            (is_nil(r.last_disconnected_at) or r.last_connected_at > r.last_disconnected_at) and
            is_nil(r.disabled_at)
        ),
      disconnected:
        filter(
          count(r.id),
          not is_nil(r.last_connected_at) and not is_nil(r.last_disconnected_at) and
            r.last_disconnected_at >= r.last_connected_at and is_nil(r.disabled_at)
        )
    })
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runners: r], r.id in ^ids)
    |> select([runners: r], {r.id, field(r, ^field)})
  end

  def group_summary(queryable \\ not_deleted()) do
    queryable
    |> group_by([runners: r], r.group)
    |> select([runners: r], {r.group, count(r.id)})
    |> order_by([runners: r], asc: r.group)
  end

  # Connection-record state from the DURABLE `last_connected_at` /
  # `last_disconnected_at` columns — NOT live Presence. Drives the fleet-wide
  # ops gauge (`Runners.connection_counts/0`); the per-account UI uses Presence
  # (`by_connection/3`), which catches an ungraceful socket drop these columns
  # only learn about on the next `disconnect_runner`/reconnect.
  def disabled(queryable \\ all()),
    do: where(queryable, [runners: r], not is_nil(r.disabled_at))

  def never_connected(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.last_connected_at))

  def connected(queryable \\ all()) do
    where(
      queryable,
      [runners: r],
      not is_nil(r.last_connected_at) and
        (is_nil(r.last_disconnected_at) or r.last_connected_at > r.last_disconnected_at)
    )
  end

  @doc """
  Connected, OR deliberately parked with `disable`.

  Pack retention uses this rather than `connected/1`: a disabled runner is
  offline by definition, so the connected set excluded it and the sweep deleted
  its trust pins — including trusted ones — which re-enable could not recover.
  A merely DISCONNECTED runner is not shielded; that ages out normally.
  """
  def connected_or_disabled(queryable \\ all()) do
    where(
      queryable,
      [runners: r],
      not is_nil(r.disabled_at) or
        (not is_nil(r.last_connected_at) and
           (is_nil(r.last_disconnected_at) or r.last_connected_at > r.last_disconnected_at))
    )
  end

  def disconnected(queryable \\ all()) do
    where(
      queryable,
      [runners: r],
      not is_nil(r.last_connected_at) and not is_nil(r.last_disconnected_at) and
        r.last_disconnected_at >= r.last_connected_at
    )
  end

  # Last recorded disconnect is older than `cutoff` — the inactivity-retention
  # sweep composes this onto `disconnected/1`, so a runner that reconnected
  # (a later `last_connected_at`) no longer matches and is never swept.
  def last_disconnected_before(queryable \\ all(), cutoff),
    do: where(queryable, [runners: r], r.last_disconnected_at < ^cutoff)

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runners, :asc, :group}, {:runners, :asc, :name}, {:runners, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads, do: [online?: &Emisar.Runners.preload_runners_presence/1]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :group_or_name,
        title: "Group or name",
        type: :string,
        fun: fn queryable, term ->
          pattern = Like.contains(term)

          {queryable,
           dynamic(
             [runners: r],
             ilike(r.group, ^pattern) or ilike(r.name, ^pattern)
           )}
        end
      }
    ]
end
