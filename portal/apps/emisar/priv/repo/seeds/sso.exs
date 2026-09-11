defmodule Emisar.Seeds.SSO do
  @moduledoc """
  The dev-stack identity provider: a Keycloak OIDC connection on the demo
  (enterprise) account, its fixed SCIM bearer, and a slice of directory state
  so the SSO connection page demonstrates group sync end to end. Every step is
  gated on the fixed-dev-value env vars, so a prod-style seed creates none of it.
  """

  alias Emisar.Accounts
  alias Emisar.Repo
  alias Emisar.Seeds.Helpers
  alias Emisar.SSO
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  @scim_token_env "EMISAR_DEV_FIXED_SCIM_TOKEN"

  def run(ctx) do
    provider_id =
      System.get_env("EMISAR_DEV_KEYCLOAK_PROVIDER_ID") || "11111111-1111-7111-8111-111111111111"

    seed_keycloak_provider(ctx, provider_id)
    reconcile_scim_token(ctx, provider_id)
    seed_scim_directory(ctx, provider_id)
    :ok
  end

  # -- Keycloak OIDC + SCIM provider (./run e2e SSO) -----------------
  #
  # Seeds an enabled :keycloak IdentityProvider on the demo (enterprise) account
  # pointing at the local Keycloak, plus a fixed dev SCIM bearer — so the shared
  # dev stack exercises OIDC login AND inbound SCIM provisioning end to end.
  # Gated on the same fixed-dev-value env vars as the auth/MCP keys; a no-op when
  # unset, so a prod-style seed never creates an IdP. Idempotent (skips if the
  # account already has a provider and reconciles SCIM on the known dev provider).
  defp seed_keycloak_provider(%{account: account}, provider_id) do
    keycloak_secret = System.get_env("EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET")

    keycloak_present? =
      IdentityProvider.Query.not_deleted()
      |> IdentityProvider.Query.by_account_id(account.id)
      |> Repo.exists?()

    if not keycloak_present? and is_binary(keycloak_secret) and keycloak_secret != "" do
      issuer =
        System.get_env("EMISAR_DEV_KEYCLOAK_ISSUER") || "https://keycloak:8443/realms/emisar"

      # Build the row directly (Changeset.change, not create): the dev Keycloak runs
      # as the portal's localhost sidecar, so its issuer is a loopback URL — which
      # `IssuerUrl` (the SSRF guard in Changeset.create) correctly rejects for
      # OPERATOR-supplied issuers. The seed is trusted infra pointing at a known dev
      # provider, not attacker input, so it bypasses that guard; the console config
      # path stays fully guarded.
      {:ok, _provider} =
        %IdentityProvider{}
        |> Ecto.Changeset.change(%{
          id: provider_id,
          account_id: account.id,
          kind: :keycloak,
          name: "Keycloak (dev)",
          issuer: issuer,
          client_id: System.get_env("EMISAR_DEV_KEYCLOAK_CLIENT_ID") || "emisar-portal",
          client_secret: keycloak_secret,
          identifier_claim: :sub,
          default_role: :operator,
          satisfies_mfa: true,
          provisioner: :jit,
          enabled: true
        })
        |> Repo.insert()

      Helpers.say("✓ Seeded Keycloak OIDC provider (#{issuer})", IO.ANSI.green())
    end
  end

  defp reconcile_scim_token(%{account: account}, provider_id) do
    case System.get_env(@scim_token_env) do
      raw when is_binary(raw) and byte_size(raw) > 12 ->
        provider =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_account_id(account.id)
          |> IdentityProvider.Query.by_id(provider_id)
          |> Repo.peek()

        if provider do
          {:ok, _} =
            provider
            |> IdentityProvider.Changeset.scim_token(
              String.slice(raw, 0, 12),
              Emisar.Crypto.hash(raw),
              true
            )
            |> Repo.update()
        end

      _ ->
        :ok
    end
  end

  # -- SCIM directory groups + memberships (docker-compose e2e SSO) -----
  #
  # Seed a slice of directory state on the Keycloak provider so the SSO connection
  # page demonstrates group sync end to end: provisioned identities, the IdP groups
  # they belong to (with real member counts), and role mappings for two of the
  # three groups (one left unmapped, to show that state in the "Synced groups"
  # readout). Uses the real SCIM + mapping entry points, so it exercises the same
  # path an IdP + admin would, and is idempotent — re-provisioning/re-upserting
  # reconciles, a duplicate mapping is ignored. Gated on the same fixed-dev SCIM
  # token as the enablement above, so it runs on any dev/e2e seed (fresh or repeat)
  # and never in a prod-style one.
  defp seed_scim_directory(%{account: account, owner_subject: owner_subject}, provider_id) do
    if System.get_env(@scim_token_env) not in [nil, ""] do
      # Deterministic on purpose. This block used to look for a SCIM-ENABLED provider
      # and silently do nothing when it found none, so whether the seeded database
      # had directory members depended on invisible state — and the docs captures for
      # the team and SSO pages came out empty with a seed that reported success.
      #
      # `./run seed` always sets this token alongside the OIDC secret, so reaching
      # here with no provider at all means something upstream genuinely failed. Say
      # so. A provider that exists but has SCIM off is repaired instead, which is
      # what makes a re-seed over an older database converge.
      scim_provider =
        case IdentityProvider.Query.not_deleted()
             |> IdentityProvider.Query.by_account_id(account.id)
             |> IdentityProvider.Query.by_id(provider_id)
             |> Repo.peek() do
          %IdentityProvider{scim_enabled: true} = enabled ->
            enabled

          %IdentityProvider{} = provider ->
            {:ok, enabled, _raw_token} = SSO.enable_scim(provider, owner_subject)
            enabled

          nil ->
            raise """
            EMISAR_DEV_FIXED_SCIM_TOKEN is set, so this seed is meant to create directory-sync state, but the demo account has no Keycloak provider to attach it to. The team and SSO docs captures need those members. Check that Keycloak came up and that EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET reached the seed.\
            """
        end

      seed_directory_state(account, owner_subject, scim_provider)
    end
  end

  defp seed_directory_state(account, owner_subject, scim_provider) do
    scim_people = [
      {"kc|nadia", "nadia@northstar.example", "Nadia Okafor"},
      {"kc|ravi", "ravi@northstar.example", "Ravi Menon"},
      {"kc|lena", "lena@northstar.example", "Lena Fischer"},
      {"kc|theo", "theo@northstar.example", "Theo Alvarez"}
    ]

    identity_ids_by_external_id =
      Map.new(scim_people, fn {ext, email, name} ->
        {:ok, %{identity: identity}} =
          SSO.scim_provision_user(scim_provider, %{
            external_id: ext,
            email: email,
            full_name: name
          })

        {ext, identity.id}
      end)

    # Certifying against a live IdP points a real directory at this connection,
    # which leaves behind identities the seed never created (an operator's own
    # Okta sign-in, an IdP's activation probe) and SCIM can only deactivate,
    # never remove — so they linger in the "Synced users" card and would ship in
    # its docs capture. Converge on the four synthetic people above: drop the
    # stray identity and the account membership it provisioned.
    seeded_external_ids = Enum.map(scim_people, fn {ext, _email, _name} -> ext end)

    stray_identities =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_id(scim_provider.id)
      |> Repo.all()
      |> Enum.reject(&(&1.provider_identifier in seeded_external_ids))

    for identity <- stray_identities do
      {:ok, _} =
        identity
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update()

      membership_query =
        Accounts.Membership.Query.not_deleted()
        |> Accounts.Membership.Query.by_account_and_user(
          identity.account_id,
          identity.user_id
        )

      for membership <- Repo.all(membership_query) do
        {:ok, _} =
          membership
          |> Accounts.Membership.Changeset.delete()
          |> Repo.update()
      end
    end

    # {external group id, display, member externalIds resolved below, mapped role | nil}
    scim_groups = [
      {"kc-grp-platform", "Platform Engineers", ~w(kc|nadia kc|ravi kc|lena), :admin},
      {"kc-grp-sre", "SRE On-call", ~w(kc|ravi kc|theo), :operator},
      {"kc-grp-security", "Security Review", ~w(kc|nadia), nil}
    ]

    # A mapping belongs to an exact server-owned SCIM group resource. Create the
    # empty resources first, map their immutable ids, then sync members so each
    # push recomputes against the mapping. Leave "Security Review" unmapped.
    scim_groups_by_external_id =
      Map.new(scim_groups, fn {ext, display, _members, _role} ->
        {:ok, group} =
          SSO.scim_upsert_group(scim_provider, %{
            external_id: ext,
            display: display,
            member_ids: []
          })

        {ext, group}
      end)

    # A duplicate mapping on a repeat seed is expected — ignore it.
    for {ext, _display, _members, role} <- scim_groups, not is_nil(role) do
      case SSO.create_group_mapping(
             scim_provider,
             %{
               "directory_group_id" => Map.fetch!(scim_groups_by_external_id, ext).id,
               "role" => to_string(role)
             },
             owner_subject
           ) do
        {:ok, _} -> :ok
        {:error, _already_mapped} -> :ok
      end
    end

    for {ext, display, members, _role} <- scim_groups do
      {:ok, _} =
        SSO.scim_upsert_group(scim_provider, %{
          external_id: ext,
          display: display,
          member_ids: Enum.map(members, &Map.fetch!(identity_ids_by_external_id, &1))
        })
    end

    # The push above lands at seed time, so without a backdate the roster's
    # newest-first order leads with four identical never-active directory rows,
    # and the connection card reads the amber "never synced" — a seeded fixture
    # presenting itself as broken. The directory connected before the newest
    # teammates joined, so its batch sorts behind every standing member, and the
    # provider is stamped the way an authenticated SCIM request would.
    scim_synced_at = Helpers.days_ago(45)

    synced_identities =
      UserIdentity.Query.not_deleted()
      |> UserIdentity.Query.by_provider_id(scim_provider.id)
      |> Repo.all()

    Enum.each(synced_identities, fn identity ->
      identity |> Ecto.Changeset.change(inserted_at: scim_synced_at) |> Repo.update!()

      case Accounts.peek_sync_membership(account.id, identity.user_id) do
        nil ->
          :ok

        membership ->
          membership
          |> Ecto.Changeset.change(inserted_at: scim_synced_at)
          |> Repo.update!()
      end
    end)

    scim_provider
    |> Ecto.Changeset.change(
      scim_last_seen_at: Helpers.mins_ago(14),
      scim_groups_synced_at: scim_synced_at
    )
    |> Repo.update!()

    Helpers.say(
      "✓ Seeded SCIM directory: #{length(scim_people)} identities, #{length(scim_groups)} groups",
      IO.ANSI.green()
    )
  end
end
