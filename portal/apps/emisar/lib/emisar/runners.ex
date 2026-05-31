defmodule Emisar.Runners do
  @moduledoc """
  Runner lifecycle: registration, auth-key management, token mint/verify,
  state advertisement persistence, heartbeats, connection state.

  Reads/writes go through `Runner.Query` + `Runner.Changeset` (and
  similar per-entity modules under `Emisar.Runners.AuthKey`,
  `Token`, `EventCursor`). The public surface takes `%Subject{}` and
  routes through `Authorizer.for_subject/2`; the runner-socket-driven
  state helpers (`apply_state`, `mark_connected`, `mark_disconnected`,
  `record_heartbeat`, `mark_event_acked`, `event_acked?`) are internal
  to the runner connection process and called with the runner
  socket's own subject upstream.
  """

  alias Emisar.{Audit, Auth, PubSub, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.{Authorizer, AuthKey, EventCursor, Runner, Token}

  # 11 chars for "emkey-auth-" + 16 random chars => 27.
  @auth_key_prefix_size 27
  # 7 chars for "rnrtok-" + 5 random.
  @token_prefix_size 12
  @key_secret_size 32

  # Per-account ring cap for auto-generated, unused install keys.
  # Dashboard mounts mint into the ring; when capacity is exceeded the
  # oldest auto-unused entry is evicted (see `mint_install_key/2`).
  @install_ring_cap 42
  @install_eviction_grace_seconds 60

  # -- Runners: reads --------------------------------------------------

  @doc """
  Batch resolver returning `%{runner_id => runner_name}` for the
  supplied ids. Used by list pages that have foreign-key references
  to runners and want labels without N+1 lookups.

  Label batches are intentionally subjectless — the caller has already
  authorized a parent listing (with its own Subject) and is rendering
  labels for ids it already trusts.
  """
  def runner_labels_for_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Runner.Query.all()
        |> Runner.Query.select_labels(ids, :name)
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  Flat list of all runners for an account. Used by the grouped
  RunnersLive UI which sorts the rows client-side by group; no
  pagination needed because real fleets are small (≪ 100 runners).
  Use `list_runners_page/2` for paginated/filterable surfaces.

  Returns `{:ok, [runner], %Paginator.Metadata{}}` per the
  context-function convention. The `:membership_id` opt restricts the
  result to runners the membership is allowed to see (post-DB filter;
  empty scopes = all).
  """
  def list_runners_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      {membership_id, opts} = Keyword.pop(opts, :membership_id)
      {group, opts} = Keyword.pop(opts, :group)
      {status, opts} = Keyword.pop(opts, :status)

      Runner.Query.not_deleted()
      |> Runner.Query.ordered_by_group_name()
      |> apply_runner_opts(group: group, status: status)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runner.Query, opts)
      |> apply_scope_filter(membership_id)
    end
  end

  # Per-user runner ACLs (v1 — uniform per-membership scope). When the
  # caller passes `membership_id: id`, restrict the result to runners
  # the membership is allowed to see (empty scopes = all). Defaults to
  # no filter so MCP/system paths keep working unchanged.
  defp apply_scope_filter({:ok, runners, metadata}, nil), do: {:ok, runners, metadata}

  defp apply_scope_filter({:ok, runners, metadata}, membership_id) do
    case Emisar.Accounts.runner_scopes_for_membership(membership_id) do
      [] -> {:ok, runners, metadata}
      scopes -> {:ok, Enum.filter(runners, &Emisar.Accounts.runner_in_scope?(&1, scopes)), metadata}
    end
  end

  defp apply_scope_filter({:error, _} = err, _), do: err

  defp apply_runner_opts(query, opts) do
    Enum.reduce(opts, query, fn
      {:group, group}, q when is_binary(group) -> Runner.Query.by_group(q, group)
      {:status, status}, q when is_binary(status) -> Runner.Query.by_status(q, status)
      _, q -> q
    end)
  end

  @doc """
  Paginated + filterable list. Returns `{:ok, [runner], metadata}`.
  Wired through `Emisar.Repo.list/3` so the LiveTable component can
  drive it from URL params.
  """
  def list_runners_page(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      Runner.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runner.Query, opts)
    end
  end

  @doc """
  Group → count tuples for the RunnersLive sidebar. Returns
  `{:ok, [{group, count}]} | {:error, :unauthorized}`. Small bounded
  set (groups, not runners) — no pagination needed.
  """
  def list_group_summaries(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      rows =
        Runner.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Runner.Query.group_summary()
        |> Repo.all()

      {:ok, rows}
    end
  end

  def fetch_runner_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runner.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Internal lookup by id only — used by socket-driven state updates."
  def peek_runner_by_id(id) do
    if Repo.valid_uuid?(id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(id)
      |> Repo.fetch(Runner.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal lookup by `external_id` scoped to an account. Used inside
  `register_via_auth_key/2`; not exposed to LiveView/MCP — they don't
  have an external_id at the auth boundary.
  """
  def fetch_runner_by_external_id_for_account(external_id, account_id) when is_binary(external_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_external_id(external_id)
    |> Repo.fetch(Runner.Query)
  end

  # -- Runners: mutations ----------------------------------------------

  def create_runner(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ) do
      %Emisar.Accounts.Account{id: account.id}
      |> Runner.Changeset.create(attrs)
      |> Repo.insert()
    end
  end

  def update_runner(%Runner{} = runner, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- ensure_runner_in_subject_account(runner, subject) do
      runner |> Runner.Changeset.update(attrs) |> Repo.update()
    end
  end

  def disable_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- ensure_runner_in_subject_account(runner, subject) do
      case runner |> Runner.Changeset.disable() |> Repo.update() do
        {:ok, disabled} = ok ->
          Audit.log(disabled.account_id, "runner.disabled",
            actor_kind: actor_kind(subject),
            actor_id: actor_id(subject),
            subject_kind: "runner",
            subject_id: disabled.id,
            subject_label: disabled.name
          )

          ok

        err ->
          err
      end
    end
  end

  @doc """
  Soft-deletes a runner — sets `deleted_at`. The runner becomes
  invisible from the default scope (`Query.not_deleted/1`) but
  historical references (audit events, run rows) remain intact.
  """
  def delete_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- ensure_runner_in_subject_account(runner, subject) do
      case runner |> Runner.Changeset.delete() |> Repo.update() do
        {:ok, deleted} = ok ->
          Audit.log(deleted.account_id, "runner.deleted",
            actor_kind: actor_kind(subject),
            actor_id: actor_id(subject),
            subject_kind: "runner",
            subject_id: deleted.id,
            subject_label: deleted.name
          )

          ok

        err ->
          err
      end
    end
  end

  defp ensure_runner_in_subject_account(%Runner{account_id: account_id}, %Subject{} = subject),
    do: Subject.ensure_in_account(subject, account_id)

  defdelegate actor_kind(subject), to: Subject
  defdelegate actor_id(subject), to: Subject

  # -- Runner socket-driven state updates ------------------------------
  #
  # These are called from the runner WebSocket process — the auth gate
  # is the socket-level token check, and the calling process IS the
  # runner. No Subject thread necessary; row id + account_id come off
  # the runner struct itself.

  def apply_state(%Runner{} = runner, %{} = payload) do
    runner
    |> Runner.Changeset.apply_state(%{
      hostname: payload["hostname"] || runner.hostname,
      labels: payload["labels"] || runner.labels,
      runner_version: payload["version"] || runner.runner_version,
      packs: payload["packs"] || runner.packs,
      external_id: payload["runner_id"] || runner.external_id
    })
    |> Repo.update()
  end

  def mark_connected(%Runner{} = runner) do
    runner
    |> Runner.Changeset.connected()
    |> Repo.update()
    |> broadcast(:runner_connected)
  end

  def mark_connected(runner_id) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      {:ok, runner} -> mark_connected(runner)
      {:error, :not_found} = err -> err
    end
  end

  def mark_disconnected(runner_or_id, reason \\ nil)

  def mark_disconnected(%Runner{} = runner, reason) do
    runner
    |> Runner.Changeset.disconnected(reason)
    |> Repo.update()
    |> broadcast(:runner_disconnected)
  end

  def mark_disconnected(runner_id, reason) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      {:ok, runner} -> mark_disconnected(runner, reason)
      {:error, :not_found} = err -> err
    end
  end

  def record_heartbeat(%Runner{} = runner, action_load),
    do: runner |> Runner.Changeset.heartbeat(action_load) |> Repo.update()

  def record_heartbeat(runner_id, action_load) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      {:ok, runner} -> record_heartbeat(runner, action_load)
      {:error, :not_found} = err -> err
    end
  end

  # -- Auth keys -------------------------------------------------------

  def list_auth_keys(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      AuthKey.Query.visible_to_operators()
      |> AuthKey.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(AuthKey.Query, Keyword.put_new(opts, :preload, :created_by))
    end
  end

  def create_auth_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      account_id = account.id
      user_id = actor_id(subject)
      {raw, prefix, hash} = mint_secret("emkey-auth-", @auth_key_prefix_size)
      changeset = AuthKey.Changeset.create(account_id, user_id, prefix, hash, attrs)

      case Repo.insert(changeset) do
        {:ok, key} ->
          Audit.log(account_id, "auth_key.created",
            actor_kind: "user",
            actor_id: user_id,
            subject_kind: "auth_key",
            subject_id: key.id,
            payload: %{prefix: key.key_prefix, reusable: key.reusable, group: key.group}
          )

          {:ok, raw, key}

        err ->
          err
      end
    end
  end

  @doc false
  # Seed/test helper that persists an auth key with a caller-supplied
  # raw secret. Production paths MUST use `create_auth_key/2` so the
  # secret is randomized server-side. A known raw value defeats the
  # randomization that makes auth keys worth anything as credentials.
  def create_auth_key_with_secret(raw, account_id, user_id, attrs \\ %{})
      when is_binary(raw) and byte_size(raw) >= @auth_key_prefix_size do
    prefix = String.slice(raw, 0, @auth_key_prefix_size)
    hash = :crypto.hash(:sha256, raw)

    AuthKey.Changeset.create(account_id, user_id, prefix, hash, attrs)
    |> Repo.insert()
  end

  @doc """
  Mints a fresh, single-use bootstrap auth key for the dashboard's
  install command, marks it auto-generated, and evicts the oldest
  auto-unused key beyond the per-account ring cap of #{@install_ring_cap}.

  Returns `{:ok, raw_secret, key}`. No audit log on mint — auto-gen is
  noise. Once a runner registers with the key, `consume_auth_key/1`
  clears the auto flag and audit logs `auth_key.bound` with `auto: true`.
  """
  def mint_install_key(%Subject{account: account} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_install_key_permission()
           ) do
      account_id = account.id
      user_id = actor_id(subject)
      cap = opts[:ring_cap] || @install_ring_cap
      grace_s = opts[:eviction_grace_seconds] || @install_eviction_grace_seconds

      {raw, prefix, hash} = mint_secret("emkey-auth-", @auth_key_prefix_size)

      Repo.transaction(fn ->
        # Insert first, then evict — so the account never momentarily has
        # zero auto-unused keys (which would race against concurrent
        # dashboard mounts).
        {:ok, key} =
          AuthKey.Changeset.mint_install(account_id, user_id, prefix, hash, %{})
          |> Repo.insert()

        evict_install_ring_overflow(account_id, cap, grace_s, key.auto_generated_at)
        {raw, key}
      end)
      |> case do
        {:ok, {raw, key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict_install_ring_overflow(account_id, cap, grace_seconds, now) do
    protected_floor = DateTime.add(now, -grace_seconds, :second)

    AuthKey.Query.evictable_install_overflow(account_id, cap, protected_floor)
    |> Repo.delete_all()
  end

  def revoke_auth_key(%AuthKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ),
         :ok <- ensure_auth_key_in_subject_account(key, subject) do
      by_user_id = actor_id(subject)

      case key |> AuthKey.Changeset.revoke(by_user_id) |> Repo.update() do
        {:ok, revoked} = ok ->
          Audit.log(revoked.account_id, "auth_key.revoked",
            actor_kind: "user",
            actor_id: by_user_id,
            subject_kind: "auth_key",
            subject_id: revoked.id,
            payload: %{prefix: revoked.key_prefix}
          )

          ok

        err ->
          err
      end
    end
  end

  defp ensure_auth_key_in_subject_account(%AuthKey{account_id: account_id}, %Subject{} = subject),
    do: Subject.ensure_in_account(subject, account_id)

  @doc """
  Peeks at the presented raw secret, resolving it to an `%AuthKey{}`.
  Returns nil when there's no match or the key is unusable (revoked/
  deleted/expired/single-use exhausted). Constant-time hash comparison.
  `peek_*` per CLAUDE.md §1.1 — nil-or-struct credential lookup.

  Internal — only called from the runner-register controller before
  any Subject exists. The presented raw secret IS the auth.
  """
  def peek_auth_key_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @auth_key_prefix_size do
      nil
    else
      hash = :crypto.hash(:sha256, raw)
      peek_by_prefix(raw, hash, @auth_key_prefix_size)
    end
  end

  defp peek_by_prefix(raw, hash, size) do
    if String.length(raw) < size do
      nil
    else
      prefix = String.slice(raw, 0, size)

      with %AuthKey{} = key <-
             AuthKey.Query.all() |> AuthKey.Query.by_key_prefix(prefix) |> Repo.peek(),
           true <- secure_compare(key.key_hash, hash),
           true <- AuthKey.usable?(key) do
        key
      else
        _ -> nil
      end
    end
  end

  # -- Per-runner tokens -----------------------------------------------

  @doc """
  Mints a long-lived per-runner token, persists the hash, returns
  `{raw_token, token_record}`. Internal — only called from the
  registration flow.
  """
  def mint_runner_token(%Runner{} = runner, issued_via_key_id \\ nil) do
    {raw, prefix, hash} = mint_secret("rnrtok-", @token_prefix_size)

    {:ok, token} =
      Token.Changeset.create(runner.id, issued_via_key_id, prefix, hash)
      |> Repo.insert()

    {raw, token}
  end

  @doc """
  Verifies a presented runner token. Returns `{:ok, token, runner}` or
  `{:error, :token_invalid}`. Internal — called from the runner socket
  upgrade controller before any Subject exists.
  """
  def verify_runner_token(raw) when is_binary(raw) do
    if String.length(raw) < @token_prefix_size do
      {:error, :token_invalid}
    else
      prefix = String.slice(raw, 0, @token_prefix_size)
      hash = :crypto.hash(:sha256, raw)

      with %Token{} = token <-
             Token.Query.all() |> Token.Query.by_prefix(prefix) |> Repo.peek(),
           true <- secure_compare(token.token_hash, hash),
           true <- Token.usable?(token),
           %Runner{disabled_at: nil, deleted_at: nil} = runner <-
             Runner.Query.all() |> Runner.Query.by_id(token.runner_id) |> Repo.peek() do
        {:ok, _} = token |> Token.Changeset.usage() |> Repo.update()
        {:ok, token, runner}
      else
        _ -> {:error, :token_invalid}
      end
    end
  end

  # -- Registration (auth_key -> runner + token exchange) --------------

  @doc """
  Called when a runner presents a valid auth key on first connect.
  Creates the runner record (or returns the existing one for a reusable
  key registration) and mints a fresh per-runner token. Also enforces
  the account's runner-count plan limit.

  Returns `{:ok, runner, token, raw_token}` on success or
  `{:error, reason}` / `{:error, :over_limit, plan, limit}`.

  Internal — called from the runner-register controller with only the
  raw secret in hand; the secret IS the auth, no Subject yet exists.
  """
  def register_via_auth_key(raw, attrs) when is_binary(raw) do
    case peek_auth_key_by_secret(raw) do
      nil -> {:error, :auth_key_invalid}
      %AuthKey{} = key -> register_via_auth_key(key, attrs)
    end
  end

  def register_via_auth_key(%AuthKey{} = key, attrs) do
    account = Emisar.Accounts.fetch_account_by_id!(key.account_id)
    was_auto? = AuthKey.auto_unused?(key)

    case Emisar.Billing.check_limit(account, :runners) do
      :ok ->
        Repo.transaction(fn ->
          # Atomically claim a use of this auth key. The conditional
          # UPDATE only succeeds if the key is still in a usable state
          # AT the moment of the update — defeating the race where two
          # concurrent registrations both see uses_count = 0.
          case consume_auth_key(key) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          # Surface the auto→permanent promotion. The mint itself was
          # deliberately silent (would flood the log with noise), so
          # binding is where this key first becomes visible.
          if was_auto? do
            Audit.log(key.account_id, "auth_key.bound",
              actor_kind: "system",
              subject_kind: "auth_key",
              subject_id: key.id,
              payload: %{prefix: key.key_prefix, auto: true}
            )
          end

          external_id = attrs[:external_id] || Ecto.UUID.generate()

          runner =
            case fetch_runner_by_external_id_for_account(external_id, key.account_id) do
              {:ok, %Runner{} = existing} ->
                existing

              {:error, :not_found} ->
                {:ok, runner} =
                  Runner.Changeset.register(%{
                    account_id: key.account_id,
                    name: derive_name(attrs),
                    external_id: external_id,
                    group: attrs[:group] || key.group || "default",
                    hostname: attrs[:hostname],
                    labels: attrs[:labels] || %{},
                    runner_version: attrs[:runner_version],
                    bootstrap_auth_key_id: key.id
                  })
                  |> Repo.insert()

                runner
            end

          {raw_token, token} = mint_runner_token(runner, key.id)
          {runner, token, raw_token}
        end)
        |> case do
          {:ok, {runner, token, raw_token}} -> {:ok, runner, token, raw_token}
          {:error, reason} -> {:error, reason}
        end

      {:error, :over_limit, plan, limit} ->
        {:error, :over_limit, plan, limit}
    end
  end

  # Atomically charge one use against `key`. The WHERE clause
  # re-evaluates every `usable?` condition at SQL level so we can't
  # TOCTOU between SELECT and UPDATE.
  defp consume_auth_key(%AuthKey{} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      AuthKey.Query.consumable_by_id(key.id, now)
      |> AuthKey.Query.consume_one(now)

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :auth_key_invalid}
    end
  end

  defp derive_name(attrs) do
    attrs[:hostname] || attrs[:name] ||
      "runner-#{Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)}"
  end

  # -- Event cursor (audit-upload outbox) ------------------------------
  #
  # Internal — called only by the runner socket process. The runner
  # is the authority on what its own cursor is.

  def mark_event_acked(runner_id, event_id) do
    EventCursor.Changeset.upsert(runner_id, event_id)
    |> Repo.insert(on_conflict: :nothing)
  end

  def event_acked?(runner_id, event_id) do
    EventCursor.Query.all()
    |> EventCursor.Query.by_runner_id(runner_id)
    |> EventCursor.Query.by_event_id(event_id)
    |> Repo.exists?()
  end

  # -- Helpers ---------------------------------------------------------

  defp mint_secret(prefix, expected_prefix_size) do
    rand = :crypto.strong_rand_bytes(@key_secret_size) |> Base.url_encode64(padding: false)
    raw = prefix <> rand
    {raw, String.slice(raw, 0, expected_prefix_size), :crypto.hash(:sha256, raw)}
  end

  defdelegate secure_compare(a, b), to: Emisar.Crypto

  # Wraps a Repo.update result, broadcasting on success.
  defp broadcast({:ok, runner} = ok, event) do
    PubSub.broadcast_runner(runner, event)
    ok
  end

  defp broadcast(err, _event), do: err
end
