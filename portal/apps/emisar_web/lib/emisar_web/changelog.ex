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
        "A ground-up pass on emisar.dev: a proof-led homepage that leads with the trust model and the \"even if our cloud is compromised, the host has the last word\" story; new Guides; a procurement-ready Trust page; a Book-a-demo path; a searchable action-pack registry; honest comparison pages; and a mobile polish pass."
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
      date: ~D[2026-06-11],
      slug: "runner-0-7-runner-scopes",
      title: "Runner 0.7 and per-user runner scopes",
      tag: nil,
      summary:
        "Runner 0.7 ships the pack-registry CLI — emisar pack install with hash-pinned installs, host-matched pack suggest, and one-command updates. Admins can scope an operator or API key to specific runners or groups. Invitation tokens joined the hashed-at-rest sweep, and MCP's wait_for_run now wakes on the run's own broadcast instead of polling."
    },
    %{
      date: ~D[2026-06-04],
      slug: "public-beta-control-plane",
      title: "Public beta control plane",
      tag: "portal-v0.1.0",
      summary:
        "Remote MCP with OAuth, scoped LLM connections, pack-trust review, contextual approvals with standing grants, live run output, team MFA controls, runbooks, OIDC SSO with SCIM directory sync, and read-only SIEM audit export."
    },
    %{
      date: ~D[2026-05-21],
      slug: "per-host-catalogs",
      title: "Per-host catalogs and content-addressed packs",
      tag: "runner-v0.2.0",
      summary: "Per-host action catalogs, content-addressed packs, and dashboard online-status."
    },
    %{
      date: ~D[2026-04-03],
      slug: "runner-hardening",
      title: "Runner hardening",
      tag: "runner-v0.1.5",
      summary:
        "PR_SET_PDEATHSIG zombie prevention, a graceful SIGTERM shutdown window, and JSONL log rotation."
    },
    %{
      date: ~D[2026-02-18],
      slug: "initial-public-release",
      title: "Initial public release",
      tag: "runner-v0.1.0",
      summary:
        "The runner binary, YAML action packs, argument validation, the policy engine, JSONL audit, and example packs."
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
