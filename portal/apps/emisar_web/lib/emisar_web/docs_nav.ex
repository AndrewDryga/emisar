defmodule EmisarWeb.DocsNav do
  @moduledoc """
  The single source of the documentation information architecture — the
  ordered, grouped page list the docs shell, sidebar, index, and prev/next
  footer all read from. Plain data only: no routes, no components. Each page
  is `%{slug, title, path, desc, icon}`; the
  `desc` is one plain sentence for the index list.
  """

  @groups [
    {"Get started",
     [
       %{
         slug: "quickstart",
         title: "Quickstart",
         path: "/docs/quickstart",
         icon: "hero-rocket-launch",
         desc: "Sign up, install a runner, run your first action in under five minutes."
       }
     ]},
    {"Connect an LLM",
     [
       %{
         slug: "connect-an-llm",
         title: "Connect a cloud LLM",
         path: "/docs/connect-an-llm",
         icon: "hero-cloud",
         desc:
           "Point Claude.ai and ChatGPT at your catalog over remote MCP and OAuth — no key to manage."
       },
       %{
         slug: "connect-a-cli-client",
         title: "Connect a CLI agent",
         path: "/docs/connect-a-cli-client",
         icon: "hero-command-line",
         desc:
           "Wire Claude Code, Cursor, Claude Desktop, and the CLIs in with the emisar-mcp bridge or a raw API key."
       }
     ]},
    {"Deploy",
     [
       %{
         slug: "host-install",
         title: "Install on a host",
         path: "/docs/host-install",
         icon: "hero-server",
         desc:
           "The full runner install: every flag, the service it creates, the config file, and the user it runs as."
       },
       %{
         slug: "containers",
         title: "Run in a container",
         path: "/docs/containers",
         icon: "hero-cube",
         desc:
           "Run the runner in a container — what it can see, the two shared mechanics, and a sidecar."
       },
       %{
         slug: "kubernetes",
         title: "Kubernetes",
         path: "/docs/kubernetes",
         icon: "hero-squares-2x2",
         desc: "One runner per node as a DaemonSet, with the pod spec as your blast-radius dial."
       },
       %{
         slug: "nomad",
         title: "Nomad",
         path: "/docs/nomad",
         icon: "hero-rectangle-stack",
         desc:
           "A Nomad system job placing one runner on every client node, with a worked HCL spec."
       },
       %{
         slug: "autoscaling-fleets",
         title: "Autoscaling fleets",
         path: "/docs/autoscaling-fleets",
         icon: "hero-cpu-chip",
         desc:
           "Enroll ephemeral runners from one reusable key as autoscaling groups — GCP MIG, AWS ASG, Azure VMSS — boot and terminate hosts."
       },
       %{
         slug: "deployment",
         title: "Production rollout",
         path: "/docs/deployment",
         icon: "hero-clipboard-document-check",
         desc: "Go from one runner to a governed fleet, with a phased rollout and a checklist."
       }
     ]},
    {"Operate",
     [
       %{
         slug: "policies-and-approvals",
         title: "Policies & approvals",
         path: "/docs/policies-and-approvals",
         icon: "hero-scale",
         desc: "Risk-tier defaults, per-action overrides, approvals, and standing grants."
       },
       %{
         slug: "runbooks",
         title: "Runbooks",
         path: "/docs/runbooks",
         icon: "hero-queue-list",
         desc:
           "Create, publish, approve, and review a staged procedure built from declared actions."
       },
       %{
         slug: "runs",
         title: "Runs & history",
         path: "/docs/runs",
         icon: "hero-play-circle",
         desc:
           "The run list and filters, every lifecycle status, live output and byte caps, cancellation, and how one dispatch's runs group."
       },
       %{
         slug: "authentication",
         title: "Authentication",
         path: "/docs/authentication",
         icon: "hero-lock-closed",
         desc: "Choose sign-in, enforcement, provisioning, and offboarding for your team."
       },
       %{
         slug: "teams-and-access",
         title: "Teams & access",
         path: "/docs/teams-and-access",
         icon: "hero-user-group",
         desc: "Roles, invitations, per-member runner scopes, MFA, sessions, and API keys."
       },
       %{
         slug: "sso",
         title: "Single sign-on (SSO)",
         path: "/docs/sso",
         icon: "hero-identification",
         desc: "OIDC sign-in, provider operations, the generic contract, and troubleshooting."
       },
       %{
         slug: "scim",
         title: "Directory sync (SCIM)",
         path: "/docs/scim",
         icon: "hero-arrow-path",
         desc:
           "SCIM 2.0 provisioning, lifecycle, protocol support, and group-driven authorization."
       },
       %{
         slug: "runners",
         title: "Runner fleet",
         path: "/docs/runners",
         icon: "hero-server-stack",
         desc: "Groups and labels, enrollment keys, pack credentials, updates, and removal."
       },
       %{
         slug: "keys",
         title: "API keys & the bridge",
         path: "/docs/keys",
         icon: "hero-key",
         desc:
           "How an MCP key inherits its operator's runner scope, minting, rotating, and revoking keys, and keeping the emisar-mcp bridge supported."
       },
       %{
         slug: "signed-dispatch",
         title: "Signed dispatch",
         path: "/docs/signed-dispatch",
         icon: "hero-finger-print",
         desc: "Make a runner run only actions a real person signed in their MCP client."
       },
       %{
         slug: "audit-and-siem",
         title: "Audit & SIEM",
         path: "/docs/audit-and-siem",
         icon: "hero-document-magnifying-glass",
         desc: "What gets recorded, the dashboard, NDJSON export, and the runner journal."
       },
       %{
         slug: "billing",
         title: "Plans & billing",
         path: "/docs/billing",
         icon: "hero-credit-card",
         desc:
           "Plan limits, feature entitlements, upgrades and downgrades, invoices, and payment failures."
       }
     ]},
    {"Integrations",
     [
       %{
         slug: "integrations-okta",
         title: "Okta",
         path: "/docs/integrations/okta",
         logo: "okta.svg",
         desc: "Okta end to end: the OIDC web app, the separate SCIM app, and group-driven roles."
       },
       %{
         slug: "integrations-entra",
         title: "Microsoft Entra",
         path: "/docs/integrations/entra",
         logo: "microsoft-entra.svg",
         desc:
           "Entra end to end: the app registration with oid, and the provisioning enterprise app."
       },
       %{
         slug: "integrations-jumpcloud",
         title: "JumpCloud",
         path: "/docs/integrations/jumpcloud",
         logo: "jumpcloud.svg",
         desc: "JumpCloud end to end: one custom application for OIDC sign-in and directory push."
       },
       %{
         slug: "integrations-keycloak",
         title: "Keycloak",
         path: "/docs/integrations/keycloak",
         logo: "keycloak.svg",
         desc: "Keycloak sign-in with PKCE, and what its missing outbound SCIM leaves you to do."
       },
       %{
         slug: "integrations-google-workspace",
         title: "Google Workspace",
         path: "/docs/integrations/google-workspace",
         logo: "google-workspace.svg",
         desc: "Google Workspace sign-in with the locked issuer, and its directory-sync gap."
       }
     ]},
    {"Build packs",
     [
       %{
         slug: "action-packs",
         title: "Pack reference",
         path: "/docs/action-packs",
         icon: "hero-cube-transparent",
         desc: "Action YAML reference: declared args, validation, limits, and redaction."
       },
       %{
         slug: "publishing-packs",
         title: "Author your own pack",
         path: "/docs/publishing-packs",
         icon: "hero-arrow-up-tray",
         desc: "Write, validate, install, and trust a pack you maintain."
       },
       %{
         slug: "pack-registry",
         title: "Host your own registry",
         path: "/docs/pack-registry",
         icon: "hero-archive-box",
         desc: "Run a private registry on GCS, S3, or any static host with packctl."
       }
     ]},
    {"Reference",
     [
       %{
         slug: "mcp-reference",
         title: "MCP reference",
         path: "/docs/mcp-reference",
         icon: "hero-code-bracket",
         desc: "Methods, parameters, idempotency, and errors — the MCP server contract."
       },
       %{
         slug: "runner-cli",
         title: "Runner CLI",
         path: "/docs/runner-cli",
         icon: "hero-command-line",
         desc:
           "The on-host emisar binary's operator verbs — connect, packs, events, audit, and signing — with their key flags."
       },
       %{
         slug: "security-model",
         title: "Security model",
         path: "/docs/security-model",
         icon: "hero-shield-check",
         desc: "Trust boundary, searchable audit, hash-chained journal, redaction on egress."
       },
       %{
         slug: "limits",
         title: "Operational limits",
         path: "/docs/limits",
         icon: "hero-adjustments-horizontal",
         desc:
           "The output, MCP, audit-export, and retention caps emisar enforces — and what happens at each."
       }
     ]}
  ]

  @flat for {_label, pages} <- @groups, page <- pages, do: page
  @by_slug Map.new(@flat, &{&1.slug, &1})
  @slug_to_group for {label, pages} <- @groups, page <- pages, into: %{}, do: {page.slug, label}

  @doc "The grouped docs IA as `[{group_label, [page]}]`, in nav order."
  def groups, do: @groups

  @doc "Every docs page in nav order, groups flattened."
  def flat, do: @flat

  @doc "The page map for `slug`; raises `KeyError` on an unknown slug."
  def fetch!(slug), do: Map.fetch!(@by_slug, slug)

  @doc "The label of the group that contains `slug`; raises on an unknown slug."
  def group_label(slug), do: Map.fetch!(@slug_to_group, slug)

  @doc "The `{prev, next}` pages around `slug` in flat order; either side may be nil."
  def prev_next(slug) do
    index = Enum.find_index(@flat, &(&1.slug == slug))
    prev = if index && index > 0, do: Enum.at(@flat, index - 1)
    next = if index, do: Enum.at(@flat, index + 1)
    {prev, next}
  end
end
