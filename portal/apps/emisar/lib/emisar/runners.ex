defmodule Emisar.Runners do
  @moduledoc """
  Runner lifecycle: registration, auth-key management, token mint/verify,
  state advertisement persistence, heartbeats, connection state.

  This module is the cloud-side analogue of the runner's bootstrap
  flow. An operator generates an auth key in the UI → drops it on a
  VM → the runner presents it on first connect → we mint a per-runner
  token and persist the registration.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Runners.{Runner, AuthKey, Token, EventCursor}

  # -- Listing / queries ------------------------------------------------

  def list_runners_for_account(account_id, opts \\ []) do
    query =
      from a in Runner,
        where: a.account_id == ^account_id,
        order_by: [asc: a.group, asc: a.name]

    query =
      if group = opts[:group] do
        where(query, [a], a.group == ^group)
      else
        query
      end

    query =
      if status = opts[:status] do
        where(query, [a], a.status == ^status)
      else
        query
      end

    Repo.all(query)
  end

  def list_groups_for_account(account_id) do
    from(a in Runner,
      where: a.account_id == ^account_id,
      group_by: a.group,
      select: {a.group, count(a.id)},
      order_by: a.group
    )
    |> Repo.all()
  end

  def get_runner(account_id, id) do
    from(a in Runner, where: a.account_id == ^account_id and a.id == ^id)
    |> Repo.one()
  end

  def get_runner!(account_id, id),
    do: get_runner(account_id, id) || raise(Ecto.NoResultsError, queryable: Runner)

  def get_runner_by_external_id(account_id, external_id) when is_binary(external_id) do
    Repo.get_by(Runner, account_id: account_id, external_id: external_id)
  end

  # -- Manual create (operator clicks "Add runner" in the UI) ------------

  def create_runner(account_id, attrs) do
    %Runner{}
    |> Runner.manual_create_changeset(Map.merge(attrs, %{"account_id" => account_id}))
    |> Repo.insert()
  end

  def update_runner(%Runner{} = runner, attrs) do
    runner
    |> Runner.manual_create_changeset(attrs)
    |> Repo.update()
  end

  def disable_runner(%Runner{} = runner, by_user_id \\ nil) do
    result =
      runner
      |> Ecto.Changeset.change(
        disabled_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        status: "disabled"
      )
      |> Repo.update()

    case result do
      {:ok, disabled} ->
        Emisar.Audit.log(disabled.account_id, "runner.disabled",
          actor_kind: if(by_user_id, do: "user", else: "system"),
          actor_id: by_user_id,
          subject_kind: "runner",
          subject_id: disabled.id,
          subject_label: disabled.name
        )

        {:ok, disabled}

      err ->
        err
    end
  end

  # -- Auth keys --------------------------------------------------------

  # 11 chars for the literal "emkey-auth-" + 16 random chars => 27.
  # The random portion has 16 chars * 6 bits/char (base64url) ≈ 96 bits
  # of entropy in the prefix alone — well past the bar where prefix
  # collisions on the unique index could be triggered by an adversary.
  @auth_key_prefix_size 27
  # Per-runner tokens use a smaller prefix (7-char "rnrtok-" + 5 random).
  # Security comes from the SHA-256 of the full secret; the prefix is
  # only a lookup hint. Keep distinct from @auth_key_prefix_size so
  # the auth-key bump doesn't invalidate tokens already minted to
  # connected runners.
  @token_prefix_size 12
  @key_secret_size 32

  @doc """
  Generates a new auth key. Returns `{raw_key, persisted_struct}`; the
  raw key is the only point at which the secret is visible.
  """
  def create_auth_key(account_id, user_id, attrs \\ %{}) do
    raw = generate_secret("emkey-auth-")
    prefix = String.slice(raw, 0, @auth_key_prefix_size)
    hash = :crypto.hash(:sha256, raw)

    params =
      attrs
      |> Map.put(:account_id, account_id)
      |> Map.put(:created_by_id, user_id)

    changeset =
      %AuthKey{}
      |> AuthKey.changeset(params)
      |> Ecto.Changeset.put_change(:key_prefix, prefix)
      |> Ecto.Changeset.put_change(:key_hash, hash)

    case Repo.insert(changeset) do
      {:ok, key} ->
        Emisar.Audit.log(account_id, "auth_key.created",
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

  def list_auth_keys(account_id) do
    from(k in AuthKey,
      where: k.account_id == ^account_id,
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  def revoke_auth_key(%AuthKey{} = key, by_user_id) do
    case key |> AuthKey.revoke_changeset(by_user_id) |> Repo.update() do
      {:ok, key} = ok ->
        Emisar.Audit.log(key.account_id, "auth_key.revoked",
          actor_kind: "user",
          actor_id: by_user_id,
          subject_kind: "auth_key",
          subject_id: key.id,
          payload: %{prefix: key.key_prefix}
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Looks up an auth key by the raw secret. Returns nil if no match or
  the key is unusable (revoked/expired/single-use exhausted).
  """
  def find_auth_key_by_secret(raw) when is_binary(raw) do
    cond do
      String.length(raw) < 12 ->
        nil

      true ->
        hash = :crypto.hash(:sha256, raw)

        # Try the current prefix size first; fall back to the legacy
        # 12-char prefix so keys minted before the prefix-size bump
        # still verify. The hash check is constant-time and binds the
        # full secret, so the fallback doesn't widen the attack surface.
        find_by_prefix(raw, hash, @auth_key_prefix_size) ||
          find_by_prefix(raw, hash, 12)
    end
  end

  defp find_by_prefix(raw, hash, size) do
    if String.length(raw) < size do
      nil
    else
      prefix = String.slice(raw, 0, size)

      with %AuthKey{} = key <- Repo.get_by(AuthKey, key_prefix: prefix),
           true <- secure_compare(key.key_hash, hash),
           true <- AuthKey.usable?(key) do
        key
      else
        _ -> nil
      end
    end
  end

  # -- Per-runner tokens -------------------------------------------------

  @doc """
  Mints a long-lived per-runner token, persists the hash, returns
  `{raw_token, token_record}`.
  """
  def mint_runner_token(%Runner{} = runner, issued_via_key_id \\ nil) do
    raw = generate_secret("rnrtok-")
    prefix = String.slice(raw, 0, @token_prefix_size)
    hash = :crypto.hash(:sha256, raw)

    {:ok, token} =
      %Token{}
      |> Token.changeset(%{
        runner_id: runner.id,
        token_prefix: prefix,
        token_hash: hash,
        issued_via_key_id: issued_via_key_id,
        issued_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.insert()

    {raw, token}
  end

  @doc """
  Verifies a presented runner token. Returns {:ok, token, runner} or
  {:error, :token_invalid}.
  """
  def verify_runner_token(raw) when is_binary(raw) do
    if String.length(raw) < @token_prefix_size do
      {:error, :token_invalid}
    else
      prefix = String.slice(raw, 0, @token_prefix_size)
      hash = :crypto.hash(:sha256, raw)

      with %Token{} = token <- Repo.get_by(Token, token_prefix: prefix),
           true <- secure_compare(token.token_hash, hash),
           true <- Token.usable?(token),
           %Runner{disabled_at: nil} = runner <- Repo.get(Runner, token.runner_id) do
        {:ok, _} = token |> Token.usage_changeset() |> Repo.update()
        {:ok, token, runner}
      else
        _ -> {:error, :token_invalid}
      end
    end
  end

  # -- Registration (auth_key -> runner + token exchange) ----------------

  @doc """
  Called when an runner presents a valid auth key on first connect.
  Creates the runner record (or returns the existing one for a reusable
  key registration) and mints a fresh per-runner token. Also enforces
  the account's runner-count plan limit.

  Accepts either a raw key string or an `%AuthKey{}` struct. Returns
  `{:ok, runner, token, raw_token}` on success or
  `{:error, reason}` / `{:error, :over_limit, plan, limit}`.
  """
  def register_via_auth_key(raw, attrs) when is_binary(raw) do
    case find_auth_key_by_secret(raw) do
      nil -> {:error, :auth_key_invalid}
      %AuthKey{} = key -> register_via_auth_key(key, attrs)
    end
  end

  def register_via_auth_key(%AuthKey{} = key, attrs) do
    account = Repo.get!(Emisar.Accounts.Account, key.account_id)

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

          external_id =
            attrs[:external_id] || attrs["external_id"] || Ecto.UUID.generate()

          runner =
            case get_runner_by_external_id(key.account_id, external_id) do
              %Runner{} = existing ->
                existing

              nil ->
                params = %{
                  account_id: key.account_id,
                  name: derive_name(attrs),
                  external_id: external_id,
                  group: attrs[:group] || attrs["group"] || key.group || "default",
                  hostname: attrs[:hostname] || attrs["hostname"],
                  labels: attrs[:labels] || attrs["labels"] || %{},
                  runner_version: attrs[:runner_version] || attrs["version"],
                  bootstrap_auth_key_id: key.id
                }

                {:ok, runner} =
                  %Runner{}
                  |> Runner.registration_changeset(params)
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

  # consume_auth_key atomically charges one use against the key. The
  # WHERE clause re-evaluates *every* usable? condition at SQL level so
  # we can't TOCTOU between SELECT and UPDATE. Returns :ok on success or
  # {:error, :auth_key_invalid} when the key is no longer usable.
  defp consume_auth_key(%AuthKey{} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from k in AuthKey,
        where: k.id == ^key.id,
        where: is_nil(k.revoked_at),
        where: is_nil(k.expires_at) or k.expires_at > ^now,
        # Single-use keys: uses_count must be 0 (and !reusable).
        # Capped reusable keys: uses_count < max_uses.
        # Unlimited reusable keys: no cap check.
        where:
          (k.reusable and (is_nil(k.max_uses) or k.uses_count < k.max_uses)) or
            (not k.reusable and k.uses_count == 0),
        update: [
          inc: [uses_count: 1],
          set: [last_used_at: ^now, updated_at: ^now]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :auth_key_invalid}
    end
  end

  defp derive_name(attrs) do
    Map.get(attrs, :hostname) || Map.get(attrs, "hostname") ||
      Map.get(attrs, :name) || Map.get(attrs, "name") ||
      "runner-#{Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)}"
  end

  # -- State updates from agent_state advertisement --------------------

  @doc """
  Applies an agent_state payload to the runner's row: hostname, labels,
  version, packs map. Side-effects (Catalog upserts) are the caller's
  responsibility — this only updates the runner itself.
  """
  def apply_state(%Runner{} = runner, %{} = payload) do
    attrs = %{
      hostname: payload["hostname"] || runner.hostname,
      labels: payload["labels"] || runner.labels,
      runner_version: payload["version"] || runner.runner_version,
      packs: payload["packs"] || runner.packs,
      external_id: payload["runner_id"] || runner.external_id
    }

    runner
    |> Runner.state_changeset(attrs)
    |> Repo.update()
  end

  def mark_connected(agent_or_id, payload \\ %{})

  def mark_connected(%Runner{} = runner, payload) do
    runner
    |> Runner.connected_changeset(payload)
    |> Repo.update()
    |> tap(fn
      {:ok, runner} -> Emisar.PubSub.broadcast_runner(runner, :runner_connected)
      _ -> :ok
    end)
  end

  def mark_connected(runner_id, payload) when is_binary(runner_id) do
    case Repo.get(Runner, runner_id) do
      nil -> {:error, :not_found}
      %Runner{} = runner -> mark_connected(runner, payload)
    end
  end

  def mark_disconnected(agent_or_id, reason \\ nil)

  def mark_disconnected(%Runner{} = runner, reason) do
    runner
    |> Runner.disconnected_changeset(reason)
    |> Repo.update()
    |> tap(fn
      {:ok, runner} -> Emisar.PubSub.broadcast_runner(runner, :runner_disconnected)
      _ -> :ok
    end)
  end

  def mark_disconnected(runner_id, reason) when is_binary(runner_id) do
    case Repo.get(Runner, runner_id) do
      nil -> {:error, :not_found}
      %Runner{} = runner -> mark_disconnected(runner, reason)
    end
  end

  def record_heartbeat(%Runner{} = runner, action_load),
    do: runner |> Runner.heartbeat_changeset(action_load) |> Repo.update()

  def record_heartbeat(runner_id, action_load) when is_binary(runner_id) do
    case Repo.get(Runner, runner_id) do
      nil -> {:error, :not_found}
      %Runner{} = runner -> record_heartbeat(runner, action_load)
    end
  end

  # -- Event cursor (audit-upload outbox) -------------------------------

  def mark_event_acked(runner_id, event_id) do
    %EventCursor{}
    |> EventCursor.changeset(%{
      runner_id: runner_id,
      event_id: event_id,
      acked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def event_acked?(runner_id, event_id) do
    Repo.exists?(
      from c in EventCursor, where: c.runner_id == ^runner_id and c.event_id == ^event_id
    )
  end

  # -- Helpers ----------------------------------------------------------

  defp generate_secret(prefix) do
    rand = :crypto.strong_rand_bytes(@key_secret_size) |> Base.url_encode64(padding: false)
    prefix <> rand
  end

  # Constant-time binary compare (Plug.Crypto has one, but a tiny
  # local helper saves the dep here in the domain app).
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  rescue
    # Older OTPs without :crypto.hash_equals/2 — fall back to the
    # constant-time loop.
    _ ->
      do_compare(a, b, 0) == 0
  end

  defp secure_compare(_, _), do: false

  defp do_compare(<<a, ra::binary>>, <<b, rb::binary>>, acc),
    do: do_compare(ra, rb, Bitwise.bor(acc, Bitwise.bxor(a, b)))

  defp do_compare(<<>>, <<>>, acc), do: acc
end
