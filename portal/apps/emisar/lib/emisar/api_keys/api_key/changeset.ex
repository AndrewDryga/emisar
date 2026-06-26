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

  def create(account_id, user_id, membership_id, prefix, hash, attrs) do
    %ApiKey{}
    |> cast(attrs, [
      :name,
      :description,
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
    |> put_default_mcp_expiry()
  end

  # Newly-minted MCP keys default to a 30-day expiry when the operator gives no
  # explicit one, so a leaked key self-heals (`usable?/1` enforces it). Audit-
  # export tokens (`audit:read`) are exempt — a log-shipping credential expiring
  # out from under a SIEM would silently break ingestion. (68a will switch this
  # scope check to the explicit `kind`.)
  @default_mcp_key_ttl_s 30 * 24 * 3_600

  defp put_default_mcp_expiry(changeset) do
    scopes = get_field(changeset, :scopes) || []

    if get_field(changeset, :expires_at) || "audit:read" in scopes do
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
