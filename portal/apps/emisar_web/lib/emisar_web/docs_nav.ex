defmodule EmisarWeb.DocsNav do
  @moduledoc """
  The single source of the documentation information architecture — the
  ordered, grouped page list the docs shell, sidebar, index, and prev/next
  footer all read from. Plain data only: no routes, no components.

  Every group has the same shape — `%{label, sections: [%{label, pages}]}` —
  so a consumer never special-cases the groups that show subgroups. A section
  `label` of `nil` means the group renders as one flat list; a non-nil label
  (Team & account's Access / Identity providers / Account) is display-only in
  the sidebar and index — it is not a route and adds no breadcrumb level.

  Each page is `%{slug, title, path, desc, icon}`, where `desc` is one plain
  sentence for the index list. Two keys are optional: `logo` replaces the icon
  with a provider mark, and `keywords` carries extra lowercase terms the
  `/docs` filter should match beyond the title, description, and group labels.
  """

  @groups [
    %{
      label: "Get started",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "quickstart",
              title: "Quickstart",
              path: "/docs/quickstart",
              icon: "hero-rocket-launch",
              keywords: "getting started setup first action install",
              desc: "Sign up, install a runner, run your first action in under five minutes."
            }
          ]
        }
      ]
    },
    %{
      label: "Connect an LLM",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "connect-an-llm",
              title: "Connect a cloud LLM",
              path: "/docs/connect-an-llm",
              icon: "hero-cloud",
              keywords: "claude.ai chatgpt remote mcp oauth",
              desc:
                "Point Claude.ai and ChatGPT at your catalog over remote MCP and OAuth — no key to manage."
            },
            %{
              slug: "connect-a-cli-client",
              title: "Connect a CLI agent",
              path: "/docs/connect-a-cli-client",
              icon: "hero-command-line",
              keywords: "claude code cursor claude desktop stdio bridge",
              desc:
                "Wire Claude Code, Cursor, Claude Desktop, and the CLIs in with the emisar-mcp bridge or a raw API key."
            },
            %{
              slug: "keys",
              title: "API keys",
              path: "/docs/keys",
              icon: "hero-key",
              keywords: "token secret bearer mint rotate revoke scope",
              desc:
                "How an MCP key inherits its operator's runner scope, and how to mint, rotate, and revoke one."
            }
          ]
        }
      ]
    },
    %{
      label: "Deploy runners",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "host-install",
              title: "Install on a host",
              path: "/docs/host-install",
              icon: "hero-server",
              keywords: "install.sh systemd service linux user",
              desc:
                "The full runner install: every flag, the service it creates, the config file, and the user it runs as."
            },
            %{
              slug: "containers",
              title: "Run in a container",
              path: "/docs/containers",
              icon: "hero-cube",
              keywords: "docker podman image sidecar",
              desc:
                "Run the runner in a container — what it can see, the two shared mechanics, and a sidecar."
            },
            %{
              slug: "kubernetes",
              title: "Kubernetes",
              path: "/docs/kubernetes",
              icon: "hero-squares-2x2",
              keywords: "k8s daemonset pod manifest",
              desc:
                "One runner per node as a DaemonSet, with the pod spec as your blast-radius dial."
            },
            %{
              slug: "nomad",
              title: "Nomad",
              path: "/docs/nomad",
              icon: "hero-rectangle-stack",
              keywords: "hashicorp hcl system job",
              desc:
                "A Nomad system job placing one runner on every client node, with a worked HCL spec."
            },
            %{
              slug: "autoscaling-fleets",
              title: "Autoscaling fleets",
              path: "/docs/autoscaling-fleets",
              icon: "hero-cpu-chip",
              keywords: "ephemeral reusable enrollment key mig asg vmss",
              desc:
                "Enroll ephemeral runners from one reusable key as autoscaling groups — GCP MIG, AWS ASG, Azure VMSS — boot and terminate hosts."
            },
            %{
              slug: "deployment",
              title: "Production rollout",
              path: "/docs/deployment",
              icon: "hero-clipboard-document-check",
              keywords: "go-live checklist monitoring phased production",
              desc:
                "Go from one runner to a governed fleet, with a phased rollout and a checklist."
            },
            %{
              slug: "network-requirements",
              title: "Network requirements",
              path: "/docs/network-requirements",
              icon: "hero-globe-alt",
              keywords: "firewall egress ports proxy dns tls websocket allowlist",
              desc:
                "What a runner host must reach on the way out — and why nothing has to reach in."
            }
          ]
        }
      ]
    },
    %{
      label: "Team & account",
      sections: [
        %{
          label: "Access",
          pages: [
            %{
              slug: "authentication",
              title: "Authentication",
              path: "/docs/authentication",
              icon: "hero-lock-closed",
              keywords: "sign-in password mfa require sso offboarding",
              desc: "Choose sign-in, enforcement, provisioning, and offboarding for your team."
            },
            %{
              slug: "teams-and-access",
              title: "Teams & access",
              path: "/docs/teams-and-access",
              icon: "hero-user-group",
              keywords: "members roles invitations permissions sessions",
              desc: "Roles, invitations, per-member runner scopes, MFA, sessions, and API keys."
            }
          ]
        },
        %{
          label: "Identity providers",
          pages: [
            %{
              slug: "sso",
              title: "Single sign-on (SSO)",
              path: "/docs/sso",
              icon: "hero-identification",
              keywords: "oidc identity provider login issuer",
              desc:
                "OIDC sign-in, provider operations, the generic contract, and troubleshooting."
            },
            %{
              slug: "scim",
              title: "Directory sync (SCIM)",
              path: "/docs/scim",
              icon: "hero-arrow-path",
              keywords: "provisioning deprovisioning groups directory bearer",
              desc:
                "SCIM 2.0 provisioning, lifecycle, protocol support, and group-driven authorization."
            },
            %{
              slug: "integrations-okta",
              title: "Okta",
              path: "/docs/integrations/okta",
              logo: "okta.svg",
              keywords: "oidc scim provisioning",
              desc:
                "Okta end to end: the OIDC web app, the separate SCIM app, and group-driven roles."
            },
            %{
              slug: "integrations-entra",
              title: "Microsoft Entra",
              path: "/docs/integrations/entra",
              logo: "microsoft-entra.svg",
              keywords: "azure active directory oidc scim oid",
              desc:
                "Entra end to end: the app registration with oid, and the provisioning enterprise app."
            },
            %{
              slug: "integrations-jumpcloud",
              title: "JumpCloud",
              path: "/docs/integrations/jumpcloud",
              logo: "jumpcloud.svg",
              keywords: "oidc scim directory push",
              desc:
                "JumpCloud end to end: one custom application for OIDC sign-in and directory push."
            },
            %{
              slug: "integrations-keycloak",
              title: "Keycloak",
              path: "/docs/integrations/keycloak",
              logo: "keycloak.svg",
              keywords: "oidc pkce realm client",
              desc:
                "Keycloak sign-in with PKCE, and what its missing outbound SCIM leaves you to do."
            },
            %{
              slug: "integrations-google-workspace",
              title: "Google Workspace",
              path: "/docs/integrations/google-workspace",
              logo: "google-workspace.svg",
              keywords: "oidc google directory",
              desc: "Google Workspace sign-in with the locked issuer, and its directory-sync gap."
            }
          ]
        },
        %{
          label: "Account",
          pages: [
            %{
              slug: "billing",
              title: "Plans & billing",
              path: "/docs/billing",
              icon: "hero-credit-card",
              keywords: "plans invoices subscription payment upgrade downgrade",
              desc:
                "Plan limits, feature entitlements, upgrades and downgrades, invoices, and payment failures."
            }
          ]
        }
      ]
    },
    %{
      label: "Govern actions",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "policies-and-approvals",
              title: "Policies & approvals",
              path: "/docs/policies-and-approvals",
              icon: "hero-scale",
              keywords: "risk tier deny allow grant approve",
              desc: "Risk-tier defaults, per-action overrides, approvals, and standing grants."
            },
            %{
              slug: "signed-dispatch",
              title: "Signed dispatch",
              path: "/docs/signed-dispatch",
              icon: "hero-finger-print",
              keywords: "certificate ca leaf signing key",
              desc: "Make a runner run only actions a real person signed in their MCP client."
            }
          ]
        }
      ]
    },
    %{
      label: "Operate",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "runners",
              title: "Runner fleet",
              path: "/docs/runners",
              icon: "hero-server-stack",
              keywords: "groups labels enrollment key offline remove",
              desc: "Groups and labels, enrollment keys, pack credentials, updates, and removal."
            },
            %{
              slug: "runs",
              title: "Runs & history",
              path: "/docs/runs",
              icon: "hero-play-circle",
              keywords: "status output cancel timeout history",
              desc:
                "The run list and filters, every lifecycle status, live output and byte caps, cancellation, and how one dispatch's runs group."
            },
            %{
              slug: "runbooks",
              title: "Runbooks",
              path: "/docs/runbooks",
              icon: "hero-queue-list",
              keywords: "procedure stages draft publish preflight",
              desc:
                "Create, publish, approve, and review a staged procedure built from declared actions."
            },
            %{
              slug: "upgrades",
              title: "Upgrade runners and MCP bridges",
              path: "/docs/upgrades",
              icon: "hero-arrow-up-circle",
              keywords: "update version canary rollback compatibility emisar-mcp",
              desc:
                "Canary runner and bridge releases, verify each batch, and keep the last known-good version ready."
            },
            %{
              slug: "credentials",
              title: "Rotate and revoke credentials",
              path: "/docs/credentials",
              icon: "hero-arrow-path-rounded-square",
              keywords: "rotation revocation secret token key overlap",
              desc:
                "Compare credential authority, overlap, and revocation consequences before you rotate or contain one."
            },
            %{
              slug: "troubleshooting",
              title: "Troubleshooting",
              path: "/docs/troubleshooting",
              icon: "hero-lifebuoy",
              keywords: "error failing broken offline denied 401 doctor diagnose",
              desc:
                "Start from the symptom: the first check, the page that owns it, and what to send if you need us."
            },
            %{
              slug: "security-incidents",
              title: "Security incidents",
              path: "/docs/security-incidents",
              icon: "hero-shield-exclamation",
              keywords: "compromise leak breach containment response evidence",
              desc:
                "Contain leaked emisar authority, preserve evidence, restore a known-good path, and verify the old authority no longer works."
            },
            %{
              slug: "audit-and-siem",
              title: "Audit & SIEM",
              path: "/docs/audit-and-siem",
              icon: "hero-document-magnifying-glass",
              keywords: "ndjson export cursor poller journal ingest",
              desc: "What gets recorded, the dashboard, NDJSON export, and the runner journal."
            }
          ]
        }
      ]
    },
    %{
      label: "Build packs",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "action-packs",
              title: "Pack reference",
              path: "/docs/action-packs",
              icon: "hero-cube-transparent",
              keywords: "yaml arguments validation redaction schema",
              desc: "Action YAML reference: declared args, validation, limits, and redaction."
            },
            %{
              slug: "publishing-packs",
              title: "Author your own pack",
              path: "/docs/publishing-packs",
              icon: "hero-arrow-up-tray",
              keywords: "write validate packctl publish sign",
              desc: "Write, validate, install, and trust a pack you maintain."
            },
            %{
              slug: "pack-updates",
              title: "Roll out and roll back packs",
              path: "/docs/pack-updates",
              icon: "hero-arrows-right-left",
              keywords: "update canary rollback content hash trust drift version",
              desc:
                "Install new pack bytes on a canary, trust the exact hash, and reinstall the prior immutable version if validation fails."
            },
            %{
              slug: "pack-registry",
              title: "Host your own registry",
              path: "/docs/pack-registry",
              icon: "hero-archive-box",
              keywords: "private gcs s3 static host packctl",
              desc: "Run a private registry on GCS, S3, or any static host with packctl."
            }
          ]
        }
      ]
    },
    %{
      label: "Reference",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "mcp-reference",
              title: "MCP reference",
              path: "/docs/mcp-reference",
              icon: "hero-code-bracket",
              keywords: "tools methods rpc idempotency errors",
              desc: "Methods, parameters, idempotency, and errors — the MCP server contract."
            },
            %{
              slug: "runner-cli",
              title: "Runner CLI",
              path: "/docs/runner-cli",
              icon: "hero-command-line",
              keywords: "emisar doctor flags journal commands",
              desc:
                "The on-host emisar binary's operator verbs — connect, packs, events, audit, and signing — with their key flags."
            },
            %{
              slug: "architecture",
              title: "Architecture and failure behavior",
              path: "/docs/architecture",
              icon: "hero-rectangle-group",
              keywords: "components topology boundaries state disconnect failure",
              desc:
                "Which component owns each decision, what crosses each boundary, and what happens when one drops out."
            },
            %{
              slug: "security-model",
              title: "Security model",
              path: "/docs/security-model",
              icon: "hero-shield-check",
              keywords: "threat trust boundary redaction retention",
              desc: "Trust boundary, searchable audit, hash-chained journal, redaction on egress."
            },
            %{
              slug: "limits",
              title: "Operational limits",
              path: "/docs/limits",
              icon: "hero-adjustments-horizontal",
              keywords: "caps quotas timeouts size retention",
              desc:
                "The output, MCP, audit-export, and retention caps emisar enforces — and what happens at each."
            }
          ]
        }
      ]
    }
  ]

  @flat for group <- @groups, section <- group.sections, page <- section.pages, do: page
  @by_slug Map.new(@flat, &{&1.slug, &1})
  @slug_to_group for group <- @groups,
                     section <- group.sections,
                     page <- section.pages,
                     into: %{},
                     do: {page.slug, group.label}

  @doc "The docs IA as `[%{label, sections: [%{label, pages}]}]`, in nav order."
  def groups, do: @groups

  @doc "Every docs page in nav order, groups and sections flattened."
  def flat, do: @flat

  @doc "The page map for `slug`; raises `KeyError` on an unknown slug."
  def fetch!(slug), do: Map.fetch!(@by_slug, slug)

  @doc "The top-level group label containing `slug`; raises on an unknown slug."
  def group_label(slug), do: Map.fetch!(@slug_to_group, slug)

  @doc "The `{prev, next}` pages around `slug` in flat order; either side may be nil."
  def prev_next(slug) do
    index = Enum.find_index(@flat, &(&1.slug == slug))
    prev = if index && index > 0, do: Enum.at(@flat, index - 1)
    next = if index, do: Enum.at(@flat, index + 1)
    {prev, next}
  end
end
