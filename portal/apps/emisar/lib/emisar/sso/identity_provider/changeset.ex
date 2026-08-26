defmodule Emisar.SSO.IdentityProvider.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.IdentityProvider

  # `kind` is set once at create (the IdP preset); update casts the rest. The
  # persisted `default_runner_scope_*` / `default_pack_scope_*` arrays are
  # deliberately NOT cast — they are derived from the raw `default_runner_scope`
  # / `default_pack_scope` selections, so a submitted array can never widen the
  # default reach.
  @config_fields ~w[name issuer client_id client_secret identifier_claim default_role
                     default_runner_access_mode default_runner_scope satisfies_mfa
                     default_pack_access_mode default_pack_scope
                     allowed_email_domain provisioner enabled]a
  @no_runner_facts %{groups: [], runners: [], packs: []}

  def create(account_id, attrs, allowlist \\ @no_runner_facts) do
    %IdentityProvider{}
    |> cast(attrs, [:kind | @config_fields])
    |> put_change(:account_id, account_id)
    |> validate_required([:account_id])
    |> validate_fields(allowlist)
  end

  def update(%IdentityProvider{} = provider, attrs, allowlist \\ @no_runner_facts) do
    provider
    |> cast(attrs, @config_fields)
    |> validate_fields(allowlist)
  end

  @doc "Form changeset for the config editor — the create validations minus the account_id only `create/3` can set."
  def form(%IdentityProvider{} = provider, attrs, allowlist \\ @no_runner_facts) do
    provider
    |> cast(attrs, [:kind | @config_fields])
    |> validate_fields(allowlist)
  end

  def delete(%IdentityProvider{} = provider),
    do: change(provider, deleted_at: DateTime.utc_now())

  @doc "Record a completed administrator sign-in against this exact configuration."
  def verify_sign_in(%IdentityProvider{} = provider, user_id, identity_id, configuration_digest)
      when is_binary(user_id) and is_binary(identity_id) and is_binary(configuration_digest) do
    change(provider,
      sign_in_verified_at: DateTime.utc_now(),
      sign_in_verified_by_user_id: user_id,
      sign_in_verified_identity_id: identity_id,
      sign_in_verified_configuration_digest: configuration_digest
    )
  end

  def bump_authorization_version(%Ecto.Changeset{} = changeset, current_version) do
    put_change(changeset, :authorization_version, current_version + 1)
  end

  @doc "Set the per-provider SCIM bearer (prefix + hash) and its enabled flag — for enable/rotate."
  def scim_token(%IdentityProvider{} = provider, prefix, hash, enabled)
      when is_binary(prefix) and is_binary(hash) and is_boolean(enabled) do
    change(provider,
      scim_token_prefix: prefix,
      scim_token_hash: hash,
      scim_enabled: enabled
    )
    |> unique_constraint(:scim_token_prefix,
      name: :sso_identity_providers_scim_token_prefix_index
    )
  end

  @doc "Disable directory sync: clear the bearer so a stale token can't authenticate, and drop the prefix's unique slot."
  def disable_scim(%IdentityProvider{} = provider) do
    change(provider,
      scim_enabled: false,
      scim_token_prefix: nil,
      scim_token_hash: nil,
      # The snapshot is discarded with the sync, so the next enable starts with
      # no group information — not with "nobody is in a group".
      scim_groups_synced_at: nil
    )
  end

  @doc "Stamp the first group push since sync was enabled; later pushes are a no-op."
  def mark_groups_synced(%IdentityProvider{scim_groups_synced_at: nil} = provider),
    do: change(provider, scim_groups_synced_at: DateTime.utc_now())

  def mark_groups_synced(%IdentityProvider{} = provider), do: change(provider, %{})

  defp validate_fields(changeset, allowlist) do
    changeset
    |> validate_required([:kind, :name, :issuer, :client_id])
    # JIT/SCIM provisioning applies `default_role` directly, so `:owner` here
    # would let a `manage_sso` admin self-provision account owners — never
    # allowed via sync (owner is a deliberate human grant needing manage_owners).
    |> validate_exclusion(:default_role, [:owner], message: "can't be owner")
    |> Emisar.Accounts.RunnerAccess.validate_selection(
      :default_runner,
      :default_runner_scope,
      :default_pack_scope,
      allowlist
    )
    |> validate_issuer()
    |> normalize_allowed_email_domain()
    |> unique_constraint([:account_id, :kind],
      name: :sso_identity_providers_account_kind_enabled_index
    )
    |> unique_constraint(:allowed_email_domain,
      name: :sso_identity_providers_allowed_email_domain_enabled_index
    )
  end

  # The issuer is the discovery base + the iss we exact-match the ID token
  # against — it must be an https URL with a host (R2/H3, no plaintext OIDC), and
  # not a private/loopback/metadata target (the login fetch is an SSRF surface;
  # `IssuerUrl` is the same guard the "Test connection" capstone runs).
  defp validate_issuer(changeset) do
    validate_change(changeset, :issuer, fn :issuer, issuer ->
      case Emisar.SSO.IssuerUrl.validate(issuer) do
        {:ok, _issuer} -> []
        {:error, :invalid_issuer} -> [issuer: "must be an https URL"]
        {:error, :blocked_issuer} -> [issuer: "can't be a private or loopback address"]
      end
    end)
  end

  # Stored citext (case-insensitive), so no downcase; just trim + strip a
  # leading "@", and treat blank as "no domain restriction".
  defp normalize_allowed_email_domain(changeset) do
    case get_change(changeset, :allowed_email_domain) do
      nil ->
        changeset

      domain ->
        normalized = domain |> String.trim() |> String.trim_leading("@")
        put_change(changeset, :allowed_email_domain, blank_to_nil(normalized))
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
