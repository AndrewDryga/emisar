defmodule Emisar.ApiKeys.ApiKey.Changeset do
  use Emisar, :changeset
  alias Emisar.ApiKeys.ApiKey

  @doc """
  Validation-only changeset for the operator create form. Casts the
  operator-facing fields and runs the same `name` validations as
  `create/6`, but mints no secret and touches no DB — so the LiveView
  can drive `phx-change` validation and render inline field errors
  without generating a key on every keystroke. `expires_at` is left
  out of the cast: the datetime-local input emits `YYYY-MM-DDTHH:MM`
  (no seconds/zone), which Ecto can't cast to `:utc_datetime_usec`; it
  round-trips for redisplay via the changeset params and is parsed when
  the key is actually created.
  """
  def form(attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
  end

  # `kind` is the sole capability discriminator (`:mcp` default; the audit page
  # passes `:audit_export`). The key carries no per-key authorization scope —
  # Policy + approval + the operator's own runner scope decide what it may do.
  def create(account_id, user_id, membership_id, prefix, hash, attrs, opts \\ []) do
    %ApiKey{}
    |> cast(attrs, [:name, :description, :kind, :expires_at])
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id, :name])
    |> validate_length(:name, min: 1, max: 80)
    |> maybe_put_default_mcp_expiry(opts)
    |> maybe_put_replaces(opts)
  end

  # The rotation back-link is an internal opt (`put_change`, never cast) — a
  # form-castable replaces_id would let a crafted create request point the
  # first-use auto-retire at an arbitrary key.
  defp maybe_put_replaces(changeset, opts) do
    case Keyword.get(opts, :replaces_id) do
      nil -> changeset
      id -> put_change(changeset, :replaces_id, id)
    end
  end

  # Newly-minted MCP keys default to a 30-day expiry when the operator gives no
  # explicit one, so a leaked key self-heals (`usable?/1` enforces it). Audit-
  # export tokens (`kind: :audit_export`) are exempt — a log-shipping credential
  # expiring out from under a SIEM would silently break ingestion.
  @default_mcp_key_ttl_s 30 * 24 * 3_600

  # OAuth backing keys opt out (`default_expiry: false`): OAuth owns their
  # lifecycle — the refresh token's own 30-day expiry retires an abandoned
  # connection and backing-key revocation is the operator off-switch — so the
  # static-key self-heal must NOT apply, or every OAuth MCP connection would die
  # 30 days after consent even while it is actively refreshing.
  defp maybe_put_default_mcp_expiry(changeset, opts) do
    if Keyword.get(opts, :default_expiry, true) do
      put_default_mcp_expiry(changeset)
    else
      changeset
    end
  end

  defp put_default_mcp_expiry(changeset) do
    if get_field(changeset, :expires_at) || get_field(changeset, :kind) == :audit_export do
      changeset
    else
      put_change(
        changeset,
        :expires_at,
        DateTime.add(DateTime.utc_now(), @default_mcp_key_ttl_s, :second)
      )
    end
  end

  def mint_quick(account_id, user_id, membership_id, prefix, hash, attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name])
    |> put_default_value(:name, "Quick connect (auto)")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:auto_generated_at, DateTime.utc_now())
    |> put_default_mcp_expiry()
    |> validate_required([:account_id, :name])
  end

  def usage(%ApiKey{} = key) do
    # First MCP call promotes an auto-minted key to permanent (visible,
    # audit-logged). Clearing auto_generated_at is the visibility flip.
    change(key, last_used_at: DateTime.utc_now(), auto_generated_at: nil)
  end

  # The MCP `initialize` clientInfo for this key — already sanitized by the
  # caller to a small string map. Snapshotted onto runs dispatched after.
  def record_client_info(%ApiKey{} = key, info) when is_map(info),
    do: change(key, last_client_info: info)

  def revoke(%ApiKey{} = key, by_user_id) do
    change(key, revoked_at: DateTime.utc_now(), revoked_by_id: by_user_id)
  end
end
