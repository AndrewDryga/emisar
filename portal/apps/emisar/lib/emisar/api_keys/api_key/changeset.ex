defmodule Emisar.ApiKeys.ApiKey.Changeset do
  use Emisar, :changeset
  alias Emisar.ApiKeys.ApiKey

  # `runbooks:execute` used to live here but the MCP API never grew
  # a runbook-dispatch endpoint, so a key minted with only that scope
  # silently couldn't do anything. Drop until we ship the endpoint.
  @valid_scopes ~w(actions:read actions:execute audit:read)

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

  def create(account_id, user_id, membership_id, prefix, hash, attrs, opts \\ []) do
    %ApiKey{}
    |> cast(attrs, [
      :name,
      :description,
      :kind,
      :runner_filter,
      :runner_group_filter,
      :scopes,
      :action_scope,
      :expires_at
    ])
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id, :name, :scopes])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_subset(:scopes, @valid_scopes)
    |> validate_action_scope()
    |> put_default_kind()
    |> validate_kind_scope_consistency()
    |> maybe_put_default_mcp_expiry(opts)
  end

  # When the caller doesn't set `kind`, derive it ONCE from the scope at mint
  # (audit:read ⇒ :audit_export, else the schema's :mcp default) so the column
  # is always explicit + queryable. This is a write-time classification, not
  # the read-time scope inference 68a removed — the list sites read `kind`.
  defp put_default_kind(changeset) do
    cond do
      get_change(changeset, :kind) ->
        changeset

      "audit:read" in (get_field(changeset, :scopes) || []) ->
        put_change(changeset, :kind, :audit_export)

      true ->
        changeset
    end
  end

  # `kind` and `scopes` must agree: an audit-export token carries `audit:read`,
  # an MCP key never does — so a miscategorised credential can't land on the
  # wrong list or dodge the default expiry. The main bite is an explicit
  # `:audit_export` lacking `audit:read`; the reverse (`:mcp` + `audit:read`)
  # is already auto-corrected to `:audit_export` by `put_default_kind` (passing
  # the `:mcp` default is a no-op change, so the scope wins).
  defp validate_kind_scope_consistency(changeset) do
    has_audit = "audit:read" in (get_field(changeset, :scopes) || [])

    if get_field(changeset, :kind) == :audit_export and not has_audit do
      add_error(changeset, :scopes, "an audit_export key must carry the audit:read scope")
    else
      changeset
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

  # Each action_scope entry is an action_id (`<pack>.<action>`, exactly one dot).
  # The pack segment may carry a hyphen (`cloud-init.analyze_show`,
  # `aws-ec2.describe_instances`), so allow `-` on both sides. This is a *bound*,
  # not a correctness gate — an entry matching no advertised action just never
  # authorizes a run — but it stops a hostile value smuggling junk into scope.
  @action_id_format ~r/^[a-z0-9_-]+\.[a-z0-9_-]+$/

  defp validate_action_scope(changeset) do
    case get_change(changeset, :action_scope) do
      nil ->
        changeset

      ids ->
        if Enum.all?(
             ids,
             &(is_binary(&1) and String.length(&1) <= 128 and &1 =~ @action_id_format)
           ) do
          changeset
        else
          add_error(changeset, :action_scope, "must be a list of action ids like \"pack.action\"")
        end
    end
  end

  def mint_quick(account_id, user_id, membership_id, prefix, hash, attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name, :runner_filter, :runner_group_filter])
    |> put_default_value(:name, "Quick connect (auto)")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:scopes, ["actions:read", "actions:execute"])
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

  def valid_scopes, do: @valid_scopes
end
