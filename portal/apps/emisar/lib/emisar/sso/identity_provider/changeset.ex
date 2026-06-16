defmodule Emisar.SSO.IdentityProvider.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.IdentityProvider

  # `kind` is set once at create (the IdP preset); update casts the rest.
  @config_fields ~w[name issuer client_id client_secret identifier_claim default_role
                     satisfies_mfa allowed_email_domain provisioner enabled]a

  def create(account_id, attrs) do
    %IdentityProvider{}
    |> cast(attrs, [:kind | @config_fields])
    |> put_change(:account_id, account_id)
    |> validate_required([:account_id])
    |> validate_fields()
  end

  def update(%IdentityProvider{} = provider, attrs) do
    provider
    |> cast(attrs, @config_fields)
    |> validate_fields()
  end

  @doc "Form changeset for the config editor — the create validations minus the account_id only `create/2` can set."
  def form(%IdentityProvider{} = provider, attrs) do
    provider
    |> cast(attrs, [:kind | @config_fields])
    |> validate_fields()
  end

  def delete(%IdentityProvider{} = provider),
    do: change(provider, deleted_at: DateTime.utc_now())

  @doc "Set the per-provider SCIM bearer (prefix + hash) and its enabled flag — for enable/rotate."
  def scim_token(%IdentityProvider{} = provider, prefix, hash, enabled)
      when is_binary(prefix) and is_binary(hash) and is_boolean(enabled) do
    change(provider,
      scim_token_prefix: prefix,
      scim_token_hash: hash,
      scim_enabled: enabled
    )
    |> unique_constraint(:scim_token_prefix,
      name: :identity_providers_scim_token_prefix_index
    )
  end

  @doc "Disable directory sync: clear the bearer so a stale token can't authenticate, and drop the prefix's unique slot."
  def disable_scim(%IdentityProvider{} = provider),
    do:
      change(provider,
        scim_enabled: false,
        scim_token_prefix: nil,
        scim_token_hash: nil
      )

  defp validate_fields(changeset) do
    changeset
    |> validate_required([:kind, :name, :issuer, :client_id])
    # JIT/SCIM provisioning applies `default_role` directly, so `:owner` here
    # would let a `manage_sso` admin self-provision account owners — never
    # allowed via sync (owner is a deliberate human grant needing manage_owners).
    |> validate_exclusion(:default_role, [:owner], message: "can't be owner")
    |> validate_issuer_https()
    |> normalize_allowed_email_domain()
    |> unique_constraint([:account_id, :kind],
      name: :identity_providers_account_kind_enabled_index
    )
    |> unique_constraint(:allowed_email_domain,
      name: :identity_providers_allowed_email_domain_enabled_index
    )
  end

  # The issuer is the discovery base + the iss we exact-match the ID token
  # against — it must be an https URL with a host (R2/H3, no plaintext OIDC).
  defp validate_issuer_https(changeset) do
    validate_change(changeset, :issuer, fn :issuer, issuer ->
      case URI.parse(issuer) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _ -> [issuer: "must be an https URL"]
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
