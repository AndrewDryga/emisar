defmodule EmisarWeb.Changelog do
  @moduledoc """
  Single source for the product changelog — rendered on `/changelog` and as
  the `/changelog.xml` RSS feed, so the two never drift. Entries are real
  shipping milestones (several carry a git tag); newest first.
  """

  @base "https://emisar.dev"

  @entries [
    %{
      date: ~D[2026-06-23],
      slug: "marketing-site-rebuilt",
      title: "The marketing site, rebuilt",
      tag: "portal-v0.9.0",
      summary:
        "A ground-up pass on emisar.dev: a proof-led homepage that leads with the trust model and the \"even if our cloud is compromised, the host has the last word\" story; new Guides; a procurement-ready Trust page; a how-it-works walkthrough traced with the real payloads at each gate; a searchable action-pack registry; honest comparison pages; and a mobile polish pass."
    },
    %{
      date: ~D[2026-06-22],
      slug: "the-gate-design-system",
      title: "\"The Gate\": a new identity and design system",
      tag: "portal-v0.8.0",
      summary:
        "emisar got a face — a new gate logo and wordmark, a single emerald brand token replacing the old indigo/emerald mix, a signature display typeface, and the operator console brought into line with the marketing site."
    },
    %{
      date: ~D[2026-06-15],
      slug: "sso-and-scim",
      title: "Enterprise SSO and SCIM",
      tag: "portal-v0.5.0",
      summary:
        "OIDC single sign-on with Google Workspace, Okta, and Keycloak, plus SCIM 2.0 directory sync — provision and deprovision from your IdP, map IdP groups to emisar roles, and have offboarding revoke a member's access and sessions automatically."
    },
    %{
      date: ~D[2026-06-08],
      slug: "runner-0-7",
      title: "Runner 0.7 and per-user scopes",
      tag: "runner-v0.7.4",
      summary:
        "The pack-registry CLI — emisar pack install with hash-pinned installs, host-matched pack suggest, and one-command updates. Per-user runner scopes limit an operator or API key to specific runners or groups; child processes are reaped with PR_SET_PDEATHSIG; and MCP's wait_for_run wakes on the run's own broadcast instead of polling."
    },
    %{
      date: ~D[2026-06-04],
      slug: "public-beta-control-plane",
      title: "Public beta control plane",
      tag: "portal-v0.1.0",
      summary:
        "The hosted control plane opens: connect any MCP client over OAuth 2.1, scope it to selected runners, and run a declared catalog behind policy. Client-attested Ed25519 signed dispatch means a compromised control plane can relay a request but never forge one; content-addressed pack trust blocks drift until an admin re-trusts; and secrets are redacted on the host before egress."
    },
    %{
      date: ~D[2026-06-01],
      slug: "approvals-audit-control-set",
      title: "Approvals, audit, and the control set",
      tag: nil,
      summary:
        "The pieces that make it safe to act: a policy engine with risk-tier defaults and ordered per-action overrides; human approvals with revocable standing grants; a SHA-256 hash-chained host journal plus a searchable cloud audit and NDJSON SIEM export; account-wide MFA with recovery codes; versioned runbooks; and per-runner billing through Paddle."
    },
    %{
      date: ~D[2026-05-29],
      slug: "mcp-and-runner",
      title: "The MCP server and the on-host runner",
      tag: nil,
      summary:
        "The two halves come together: a JSON-RPC MCP server that exposes a declared, typed action catalog to any agent (tools/list, tools/call), and an outbound-only runner that advertises and executes it on the host — plus a docker-compose dev stack and single-use runner enrollment keys."
    },
    %{
      date: ~D[2026-05-18],
      slug: "the-foundation",
      title: "The foundation",
      tag: nil,
      summary:
        "Where it began: the on-host runner, YAML action packs with typed argument validation, the risk-tiered policy engine, and an append-only JSONL audit trail — the declared-action model everything else builds on."
    }
  ]

  @doc "All changelog entries, newest first."
  def entries, do: @entries

  @doc "Display date, e.g. \"June 23, 2026\"."
  def display_date(%Date{} = date), do: Calendar.strftime(date, "%B %-d, %Y")

  @doc "RFC 822 pubDate for RSS, e.g. \"Tue, 23 Jun 2026 00:00:00 +0000\"."
  def rss_date(%Date{} = date), do: Calendar.strftime(date, "%a, %d %b %Y 00:00:00 +0000")

  @doc "Canonical URL for an entry (anchor on the changelog page)."
  def entry_url(%{slug: slug}), do: @base <> "/changelog#" <> slug
end
