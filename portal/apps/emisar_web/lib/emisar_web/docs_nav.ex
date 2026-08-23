defmodule EmisarWeb.DocsNav do
  @moduledoc """
  The single source of the documentation information architecture — the
  ordered, grouped page list the docs shell, sidebar, index, and prev/next
  footer all read from. Plain data only: no routes, no components.

  Every group has the same shape — `%{label, sections: [%{label, pages}]}` —
  so a consumer never special-cases the groups that show subgroups. A section
  `label` of `nil` means the group renders as one flat list; a non-nil label
  (Team & account's Access / Identity concepts / Provider guides / Account) is display-only in
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
              icon: "docs.quickstart",
              keywords: "getting started setup first action install",
              desc:
                "Sign up, install a runner, and run your first audited action in under five minutes."
            }
          ]
        }
      ]
    },
    %{
      label: "Runners",
      sections: [
        %{
          label: "Deploy on",
          pages: [
            %{
              slug: "host-install",
              title: "Linux host",
              path: "/docs/host-install",
              icon: "infrastructure.host",
              keywords: "install.sh systemd service linux user",
              desc:
                "The full runner install: every flag, the service it creates, the config file, and the user it runs as."
            },
            %{
              slug: "containers",
              title: "Container",
              path: "/docs/containers",
              icon: "infrastructure.container",
              keywords: "docker podman image sidecar",
              desc:
                "Run the runner in a container — what it can see, the two shared mechanics, and a sidecar."
            },
            %{
              slug: "kubernetes",
              title: "Kubernetes DaemonSet",
              path: "/docs/kubernetes",
              icon: "infrastructure.kubernetes",
              keywords: "k8s daemonset pod manifest",
              desc:
                "One runner per node as a DaemonSet, with the pod spec as your blast-radius dial."
            },
            %{
              slug: "nomad",
              title: "Nomad system job",
              path: "/docs/nomad",
              icon: "infrastructure.nomad",
              keywords: "hashicorp hcl system job",
              desc:
                "A Nomad system job placing one runner on every client node, with a worked HCL spec."
            },
            %{
              slug: "autoscaling-fleets",
              title: "Autoscaling fleets",
              path: "/docs/autoscaling-fleets",
              icon: "product.runner_fleet",
              keywords: "ephemeral reusable enrollment key mig asg vmss",
              desc:
                "Enroll ephemeral runners from one reusable key as autoscaling groups — GCP MIG, AWS ASG, Azure VMSS — boot and terminate hosts."
            }
          ]
        },
        %{
          label: "The fleet",
          pages: [
            %{
              slug: "network-requirements",
              title: "Network requirements",
              path: "/docs/network-requirements",
              icon: "infrastructure.network",
              keywords: "firewall egress ports proxy dns tls websocket allowlist",
              desc:
                "What a runner host must reach on the way out — and why nothing has to reach in."
            },
            %{
              slug: "runner-fleet",
              title: "Manage the runner fleet",
              path: "/docs/runner-fleet",
              icon: "product.runner_fleet",
              keywords: "groups labels enrollment key offline remove",
              desc: "Groups and labels, enrollment keys, pack credentials, updates, and removal."
            },
            %{
              slug: "production",
              title: "Go to production",
              path: "/docs/production",
              icon: "docs.deployment",
              keywords: "go-live checklist monitoring phased production",
              desc:
                "Go from one runner to a governed fleet, with a phased rollout and a checklist."
            },
            %{
              slug: "runner-upgrades",
              title: "Upgrade runners",
              path: "/docs/runner-upgrades",
              icon: "docs.upgrade",
              keywords: "update version canary rollback compatibility",
              desc:
                "Canary a runner release, verify each batch, and keep the last known-good version ready."
            },
            %{
              slug: "runner-credentials",
              title: "Runner credentials",
              path: "/docs/runner-credentials",
              icon: "docs.credential_rotation",
              keywords: "enrollment key runner token pack credential rotate revoke",
              desc:
                "Rotate enrollment keys, understand per-runner tokens, and swap the provider credentials packs read."
            }
          ]
        }
      ]
    },
    %{
      label: "AI agents",
      sections: [
        %{
          label: "Connect",
          pages: [
            %{
              slug: "connect-cli-agent",
              title: "CLI agent",
              path: "/docs/connect-cli-agent",
              icon: "interface.cli",
              keywords: "claude code cursor claude desktop stdio bridge",
              desc:
                "Wire Claude Code, Cursor, Claude Desktop, and the CLIs in with the emisar-mcp bridge or a raw API key."
            },
            %{
              slug: "connect-claude-ai",
              title: "Claude.ai",
              path: "/docs/connect-claude-ai",
              icon: "infrastructure.cloud",
              keywords: "claude anthropic connector custom oauth remote mcp",
              desc: "Add emisar to Claude.ai as a custom connector — no key to manage."
            },
            %{
              slug: "connect-chatgpt",
              title: "ChatGPT",
              path: "/docs/connect-chatgpt",
              icon: "infrastructure.cloud",
              keywords: "chatgpt openai developer mode connector oauth remote mcp",
              desc: "Add emisar to ChatGPT through Developer mode — no key to manage."
            },
            %{
              slug: "connect-multiple-accounts",
              title: "Multiple accounts",
              path: "/docs/connect-multiple-accounts",
              icon: "infrastructure.nomad",
              keywords:
                "multiple accounts staging production alias accounts use --account switch",
              desc:
                "One MCP server entry per account, the CLI's stored accounts, and one cloud connector per account."
            }
          ]
        },
        %{
          label: "The fleet",
          pages: [
            %{
              slug: "agents-and-keys",
              title: "Manage agents & keys",
              path: "/docs/agents-and-keys",
              icon: "product.agent",
              keywords: "agent key token secret bearer mint rotate revoke scope activity",
              desc:
                "The agents connected to your account, what each row shows, and how to mint, rotate, and revoke the key behind one."
            },
            %{
              slug: "bridge-upgrades",
              title: "Upgrade the MCP bridge",
              path: "/docs/bridge-upgrades",
              icon: "docs.upgrade",
              keywords: "update version emisar-mcp bridge rollback compatibility",
              desc:
                "Re-run the installer per workstation, prove the client relaunched the bridge, and pin a rollback."
            }
          ]
        }
      ]
    },
    %{
      label: "Action packs",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "use-a-published-pack",
              title: "Use a published pack",
              path: "/docs/use-a-published-pack",
              icon: "pack.use_published",
              keywords: "pack suggest inspect install hash credentials trust",
              desc: "Choose, inspect, install, configure, and verify a published action pack."
            },
            %{
              slug: "pack-updates",
              title: "Roll out and roll back packs",
              path: "/docs/pack-updates",
              icon: "action.sync",
              keywords: "update canary rollback content hash trust drift version",
              desc:
                "Install the new pack version on a canary, trust the hash, and keep the prior version ready."
            },
            %{
              slug: "publishing-packs",
              title: "Author your own pack",
              path: "/docs/publishing-packs",
              icon: "pack.publish",
              keywords: "write validate packctl publish sign",
              desc: "Write, validate, install, and trust a pack you maintain."
            },
            %{
              slug: "pack-registry",
              title: "Host your own registry",
              path: "/docs/pack-registry",
              icon: "catalog.registry",
              keywords: "private gcs s3 static host packctl",
              desc: "Run a private registry on GCS, S3, or any static host with packctl."
            },
            %{
              slug: "action-packs",
              title: "Pack reference",
              path: "/docs/action-packs",
              icon: "pack.reference",
              keywords: "yaml arguments validation redaction schema",
              desc: "Action YAML reference: declared args, validation, limits, and redaction."
            }
          ]
        }
      ]
    },
    %{
      label: "Operate",
      sections: [
        %{
          label: "Day to day",
          pages: [
            %{
              slug: "run-an-action",
              title: "Run an action",
              path: "/docs/run-an-action",
              icon: "action.execute",
              keywords: "dispatch console reason arguments approval result",
              desc:
                "Select a runner and action, enter its arguments, dispatch it, and read the result."
            },
            %{
              slug: "runs",
              title: "Runs & history",
              path: "/docs/runs",
              icon: "product.run",
              keywords: "status output cancel timeout history",
              desc:
                "The run list and filters, every lifecycle status, live output and byte caps, cancellation, and how one dispatch's runs group."
            },
            %{
              slug: "runbooks",
              title: "Runbooks",
              path: "/docs/runbooks",
              icon: "product.runbook",
              keywords: "procedure stages draft publish preflight",
              desc:
                "Create, publish, approve, and review a staged procedure built from declared actions."
            }
          ]
        },
        %{
          label: "When it breaks",
          pages: [
            %{
              slug: "troubleshooting",
              title: "Troubleshooting",
              path: "/docs/troubleshooting",
              icon: "product.support",
              keywords: "error failing broken offline denied 401 doctor diagnose",
              desc:
                "Start from the symptom: the first check, the page that owns it, and what to send if you need us."
            },
            %{
              slug: "security-incidents",
              title: "Security incidents",
              path: "/docs/security-incidents",
              icon: "security.incident",
              keywords: "compromise leak breach containment response evidence",
              desc:
                "Contain leaked emisar authority, preserve evidence, restore a known-good path, and verify the old authority no longer works."
            },
            %{
              slug: "credentials",
              title: "Rotate and revoke credentials",
              path: "/docs/credentials",
              icon: "docs.credential_rotation",
              keywords: "rotation revocation secret token key overlap",
              desc:
                "Compare credential authority, overlap, and revocation consequences before you rotate or contain one."
            }
          ]
        }
      ]
    },
    %{
      label: "Govern access",
      sections: [
        %{
          label: nil,
          pages: [
            %{
              slug: "policies-and-approvals",
              title: "Policies & approvals",
              path: "/docs/policies-and-approvals",
              icon: "trust.policy_enforced",
              keywords: "risk tier deny allow grant approve",
              desc: "Risk-tier defaults, per-action overrides, approvals, and standing grants."
            },
            %{
              slug: "signed-dispatch",
              title: "Signed dispatch",
              path: "/docs/signed-dispatch",
              icon: "trust.signed_dispatch",
              keywords: "certificate ca leaf signing key",
              desc:
                "A customer-authorized bridge signs each request with a key the control plane never holds."
            },
            %{
              slug: "audit-and-siem",
              title: "Audit & SIEM",
              path: "/docs/audit-and-siem",
              icon: "product.audit",
              keywords: "ndjson export cursor poller journal ingest",
              desc: "What gets recorded, the console, NDJSON export, and the runner journal."
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
              icon: "identity.authentication",
              keywords: "sign-in password mfa require sso offboarding",
              desc: "Choose sign-in, enforcement, provisioning, and offboarding for your team."
            },
            %{
              slug: "teams-and-access",
              title: "Teams & access",
              path: "/docs/teams-and-access",
              icon: "product.team",
              keywords: "members roles invitations permissions sessions",
              desc: "Roles, invitations, per-member runner scopes, MFA, sessions, and API keys."
            }
          ]
        },
        %{
          label: "Identity concepts",
          pages: [
            %{
              slug: "sso",
              title: "Single sign-on (SSO)",
              path: "/docs/sso",
              icon: "identity.authentication",
              keywords: "oidc identity provider login issuer",
              desc:
                "OIDC sign-in, provider operations, the generic contract, and troubleshooting."
            },
            %{
              slug: "scim",
              title: "Directory sync (SCIM)",
              path: "/docs/scim",
              icon: "identity.directory_sync",
              keywords: "provisioning deprovisioning groups directory bearer",
              desc:
                "SCIM 2.0 provisioning, lifecycle, protocol support, and group-driven authorization."
            }
          ]
        },
        %{
          label: "Provider guides",
          pages: [
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
              icon: "product.billing",
              keywords: "plans invoices subscription payment upgrade downgrade",
              desc:
                "Plan limits, feature entitlements, upgrades and downgrades, invoices, and payment failures."
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
              title: "MCP CLI & reference",
              path: "/docs/mcp-reference",
              icon: "interface.api",
              keywords:
                "tools methods rpc idempotency errors emisar-mcp cli shell scripting json",
              desc:
                "Use live MCP tools from the shell, and inspect the server methods, schemas, recovery rules, and errors."
            },
            %{
              slug: "runner-cli",
              title: "Runner CLI",
              path: "/docs/runner-cli",
              icon: "interface.cli",
              keywords: "emisar doctor flags journal commands",
              desc:
                "The on-host emisar binary's operator verbs — connect, packs, events, audit, and signing — with their key flags."
            },
            %{
              slug: "architecture",
              title: "Architecture and failure behavior",
              path: "/docs/architecture",
              icon: "architecture.system",
              keywords: "components topology boundaries state disconnect failure",
              desc:
                "Which component owns each decision, what crosses each boundary, and what happens when one drops out."
            },
            %{
              slug: "compatibility",
              title: "Compatibility and deprecation",
              path: "/docs/compatibility",
              icon: "docs.compatibility",
              keywords: "version semver support freeze breaking deprecation migration",
              desc:
                "The v1 compatibility promise, frozen public contracts, and deprecation window."
            },
            %{
              slug: "security-model",
              title: "Security model",
              path: "/docs/security-model",
              icon: "security.posture",
              keywords: "threat trust boundary redaction retention",
              desc: "Trust boundary, searchable audit, hash-chained journal, redaction on egress."
            },
            %{
              slug: "limits",
              title: "Operational limits",
              path: "/docs/limits",
              icon: "docs.limits",
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
