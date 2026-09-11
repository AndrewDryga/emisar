defmodule EmisarWeb.SSOProviderKind do
  @moduledoc """
  What the SSO setup guide says about each identity provider, in one table.

  Twelve private functions in `sso_settings_live.ex` each dispatched on the
  same six kinds — the label, the docs path, the issuer and where to find it,
  the app-creation hint, the directory note, the SCIM location, the name
  placeholder. Adding a seventh provider meant editing fourteen places, and
  most of those functions have a permissive fallback, so a missed one shipped
  as generic copy instead of failing to compile.

  One entry per kind now; a provider that says nothing special about a field
  falls back to the generic entry, which is what an OIDC provider we have no
  guide for gets.
  """

  @generic %{
    label: "a generic OIDC provider",
    docs_link_label: "Single sign-on docs",
    issuer: "your provider's OIDC issuer URL (the discovery base)",
    issuer_where: nil,
    oidc_app: "with your provider — a confidential web client with a client secret",
    directory_note: "Directory sync requires a provider that can send SCIM updates.",
    scim_location: "in your provider's SCIM / user-provisioning settings",
    name_placeholder: "Company SSO",
    identifier_claim_hint: "",
    dpop_relevant?: false
  }

  @kinds %{
    "google_workspace" => %{
      label: "Google Workspace",
      docs_path: "/docs/integrations/google-workspace",
      issuer: "https://accounts.google.com",
      issuer_where: "Always this exact value for Google — nothing to look up.",
      oidc_app:
        "in Google Cloud Console → Google Auth Platform → Clients → Create client (Web application)",
      directory_note: "Google Workspace doesn't support directory sync with emisar.",
      name_placeholder: "Acme Google Workspace"
    },
    "okta" => %{
      label: "Okta",
      docs_path: "/docs/integrations/okta",
      issuer: "https://YOUR-ORG.okta.com",
      issuer_where:
        "Copy your org URL from the account menu in the Okta admin console. Use the org URL without -admin or an /oauth2/… path.",
      oidc_app:
        "in the Okta admin console → Applications → Create App Integration → OIDC, Web Application",
      directory_note: "Directory sync is a second Okta app — this one only signs people in.",
      scim_location:
        "in a SEPARATE Okta app — Okta's OIDC login app can't do SCIM. Add the \"SCIM 2.0 Test App (Header Auth)\" from the OIN catalog (its Sign-On tab is unused — SCIM lives entirely on the Provisioning tab): Configure API Integration → Enable, configure the Base URL and API token as described in step 2, then enable Create / Update / Deactivate. Okta sends the token as a raw header with no `Bearer` scheme, which emisar accepts",
      name_placeholder: "Acme Okta",
      dpop_relevant?: true
    },
    "entra" => %{
      label: "Microsoft Entra",
      docs_path: "/docs/integrations/entra",
      issuer: "https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0",
      issuer_where:
        "Build it from your Directory (tenant) ID, on the app registration's Overview. The trailing `/v2.0` selects Entra's v2.0 endpoint — without it you get v1.0 tokens.",
      oidc_app:
        "in the Microsoft Entra admin center → App registrations → New registration, with a Web redirect URI",
      directory_note:
        "This is the app registration; directory sync is a separate enterprise application.",
      # Keycloak has no outbound SCIM: its own SCIM support (26.6+) makes it a
      # SCIM *server* others provision INTO, the opposite direction. Naming the
      # gap beats sending an admin hunting for a screen that doesn't exist.
      scim_location:
        "on a separate ENTERPRISE APPLICATION, not this app registration — Entra splits sign-in and provisioning across two objects. Create a non-gallery app, then Provisioning → Automatic, with the URL in step 2 as Tenant URL and the `ems-` token as Secret Token. Remap externalId to objectId, or the directory and this connection will disagree about who someone is",
      name_placeholder: "Acme Entra",
      # Entra's `sub` differs per application, so `oid` is the only claim that
      # joins sign-in to the directory — which is why it is the only one
      # offered. The reasoning belongs in the Entra guide; here the operator
      # needs the fact.
      identifier_claim_hint:
        "Entra gives every app a different `sub`, so emisar uses `oid` — the id directory sync sends."
    },
    "jumpcloud" => %{
      label: "JumpCloud",
      docs_path: "/docs/integrations/jumpcloud",
      oidc_app:
        "in the JumpCloud admin console → SSO Applications → Add New Application → Custom Application, with the OIDC connector enabled",
      directory_note: "One JumpCloud application covers both this and directory sync.",
      scim_location:
        "on a JumpCloud application's Provisioning tab — one custom app can carry both sign-in and provisioning, so tick \"Export users to this app\" alongside SSO (its SAML/OIDC sub-choice defaults to SAML). Configure the Base URL and Token as described in step 2, then Test Connection → Activate (their form discards the config if you press Save instead)",
      name_placeholder: "Acme JumpCloud"
    },
    "keycloak" => %{
      label: "Keycloak",
      docs_path: "/docs/integrations/keycloak",
      issuer: "https://YOUR-HOST/realms/YOUR-REALM",
      issuer_where:
        "Your realm's base URL; Realm settings → Endpoints → OpenID Endpoint Configuration confirms the exact value.",
      oidc_app:
        "in the Keycloak admin console → Clients → Create client → OpenID Connect (enable Client authentication)",
      directory_note: "Directory sync requires a third-party Keycloak extension.",
      scim_location:
        "from a SCIM plugin on your Keycloak — Keycloak ships no outbound provisioning of its own, so this needs a third-party extension, which you configure and support",
      name_placeholder: "Acme Keycloak",
      dpop_relevant?: true
    }
  }

  @doc "The kinds with their own guide — the ones whose docs link promises steps."
  def guided, do: Map.keys(@kinds)

  @doc """
  One field for one kind. `kind` may be the atom the schema stores or its
  string form; an unknown kind gets the generic answer, which is the one an
  OIDC provider we have no guide for should read.
  """
  def get(kind, field) do
    entry = Map.get(@kinds, to_string(kind), %{})
    Map.get(entry, field) || Map.fetch!(@generic, field)
  end

  @doc "Deep-link to the provider's own guide rather than the top of the docs."
  def docs_path(kind), do: Map.get(Map.get(@kinds, to_string(kind), %{}), :docs_path)

  @doc """
  The docs link's label. It says what the page IS, the house shape ("Runner
  docs"); a label promising screenshots needed a per-provider honesty split,
  because only four guides have full console coverage.
  """
  def docs_link_label(kind) do
    if Map.has_key?(@kinds, to_string(kind)),
      do: "Step-by-step guide",
      else: @generic.docs_link_label
  end

  @doc """
  The one sentence a provider's identifier claim needs. Entra gives every app
  a different `sub`, so emisar uses `oid` — the id directory sync sends; every
  other provider has one option and nothing to decide, so justifying a short
  list would be our bookkeeping, not the operator's.
  """
  def identifier_claim_hint(kind), do: get(kind, :identifier_claim_hint)

  @doc "Whether DPoP is worth mentioning for this provider."
  def dpop_relevant?(kind), do: get(kind, :dpop_relevant?) == true
end
