defmodule EmisarWeb.Changelog do
  @moduledoc """
  Single source for the product changelog — rendered on `/changelog` and as
  the `/changelog.xml` RSS feed, so the two never drift. Each entry is a real
  product release and carries its git tag (`vMAJOR.MINOR.0`); the tag points at
  the last commit of that version's window, so the commit history, the tags, and
  this changelog all line up. Newest first.

  Entry shape: `summary` is the highlighted main change (short connected prose);
  the optional `details` list carries everything else as `{group, [bullets]}` —
  groups render in the order given, from the fixed vocabulary Security · Runner
  · MCP · Packs · Console · Audit · Billing · Platform · Website · Also. A
  single-story patch release is summary-only.
  """

  @base "https://emisar.dev"

  @entries [
    %{
      date: ~D[2026-08-17],
      slug: "role-and-scope-changes-take-effect-immediately",
      title: "Role and scope changes take effect immediately",
      tag: "v0.41.0",
      summary:
        "Changing a member's role, runner access, or pack access now reconnects their open web session before it can keep acting on stale authority. Billing managers get a finance-only console; operators can own agents, approvals, and runbooks without team or policy administration; and scoped admins cannot delegate more reach than they hold or arm account-wide pack cleanup. Runner and pack scopes govern current discovery, targeting, and new work, while account run and audit history stays available to roles allowed to read it — including the names needed to investigate what happened.",
      details: [
        {"Security",
         [
           "Role and scope changes disconnect the member's live session and force a fresh authorization check. Account-wide pack cleanup requires full pack access, and helper reads that expose pack versions or exact run commands now require the caller's checked subject.",
           "The read-only staff console is available only after MFA, and its proof is tied to the current enrollment rather than surviving a disable-and-reenroll cycle."
         ]},
        {"Console",
         [
           "Each role now sees the navigation, actions, filters, and empty states it can actually use. Billing managers land on Billing without a dead Dashboard link; no runner access is explained as a permission state rather than mistaken for a new account; and restricted pack and action views say why their results are limited.",
           "SSO group mappings paginate in both directions. Filters keep their compact grouped treatment, timestamp and source tooltips flip away from viewport edges, and action menus close on Escape or an outside click across both app and marketing pages."
         ]},
        {"Packs",
         [
           "The 100-pack catalog now carries 1,689 actions. New diagnostics cover Consul registration churn, bounded process context and connections, GCP Cloud Logging names and entries, and Terraform replacement paths."
         ]},
        {"Platform",
         [
           "The Runner and MCP Bridge are rebuilt with Go 1.26.6 for the current standard-library advisory batch."
         ]}
      ]
    },
    %{
      date: ~D[2026-08-13],
      slug: "large-runbooks-finish-and-results-stay-readable",
      title: "Large runbooks finish, and every result stays readable",
      tag: "v0.40.0",
      summary:
        "A runbook no longer fails publication because its expanded plan crossed an arbitrary total-step ceiling. The limits that protect the service remain — 16 stages, 256 resolved items, bounded targets, waits, arguments, and output — but a useful procedure can now be as long as those real bounds allow. When a terminal result is too large for one MCP response, the first call keeps the summary and returns an opaque continuation for ordered, 64 KiB output pages with explicit progress counts; small executions still finish in one call. Action discovery now also follows the member's current runner and pack scope in the console and MCP, including open pages after access or a runner group changes.",
      details: [
        {"Security",
         [
           "Runner, pack, action, approval, and audit discovery now intersects the member's current runner and pack scope. Catalog rows require a deployment on a runner the member can see, malformed cross-account associations fail closed, and mounted console pages refresh when runner facts or the member's scope changes.",
           "Phoenix LiveView is patched past the open-redirect advisory that affected navigation targets."
         ]},
        {"Runbooks",
         [
           "The arbitrary 32-step ceiling is gone. Definition size, stage count, target fan-out, frozen-plan size, and the 256-item execution ceiling remain the bounds that stop real resource growth.",
           "Large terminal output is paged as complete records through wait_for_run. Each page names the total, returned, and remaining record counts and carries an opaque 15-minute continuation bound to the execution and credential lineage."
         ]},
        {"Runner",
         [
           "An official installer-managed runner can now update itself with emisar update. It verifies the release checksum and GitHub build attestation before handing the bundle to the same stop, swap, restart, and rollback transaction used by the installer; image and infrastructure-managed runners stay with their deployment owner.",
           "pack update --json now emits its partial report before returning a post-update validation error, so automation keeps machine-readable results on every failure path."
         ]},
        {"Packs",
         [
           "The catalog now carries 100 packs and 1,682 actions, adding JFrog Artifactory, Databricks, Sentry, Symbolicator, and NTPsec while substantially expanding Cassandra and Cloudflare operations.",
           "The admin runner's declared packs and executable checks now match what the production host actually carries."
         ]},
        {"Console",
         [
           "Approval forms now live-validate an empty restricted pack selection alongside runner scope, and an MFA enrollment completed in another tab returns to the app instead of sending the user through a misleading email-verification loop.",
           "Runbook lists show a loading state on the disconnected first render, approval evidence links directly to its audit record, and invitation completion leaves one clear receipt instead of a finished form."
         ]}
      ]
    },
    %{
      date: ~D[2026-08-09],
      slug: "one-runbook-one-unpublished-change",
      title: "One runbook, one unpublished change, and a diff before you publish",
      tag: "v0.39.0",
      summary:
        "Every save of a runbook used to mint a version, so the number counted saves rather than decisions: fifteen authoring passes were fifteen versions, and v7 could be the second thing that ever ran. Which version was live, which was a draft sitting on top of it, and which had been superseded were three facts smeared across those rows, and the editor opened whichever row you clicked — so an old version was one click from what looked like a live editor. Publishing from there made old content the newest published version and silently changed what a plain Run dispatches. A runbook is now one thing carrying one unpublished change. Publishing shows the lines that differ from what runs today, mints the next release, and clears the change; only the live release runs, an agent's edit replaces that one change under the hash it read, and every execution keeps the exact definition it started with.",
      details: [
        {"Security",
         [
           "The runner redacts more of what a config actually calls a secret: connection strings and database URLs, key-derivation inputs like salt and pepper, cookie and session signing keys, and the passphrase spellings. This is a safety net under actions that forget to declare their own redactions, never a reason to lower an action's risk tier — a key name nobody thought of still leaks.",
           "Reading a pfSense certificate no longer emits its private key, and the fleet installer keeps a reusable enrollment key off the process command line."
         ]},
        {"Runbooks",
         [
           "Publishing is a confirmation that shows the change: the lines replacing what runs today, against the exact text whose hash is the definition's identity. A first release says so instead of showing an empty diff.",
           "Only the live release runs. Naming an older one answers not_live rather than quietly running current content, and a draft runs only with explicit consent plus the hash of exactly what you read.",
           "History is inspectable and no longer editable. The runbook list names the live release on the Run button itself and marks waiting changes with a quiet dot."
         ]},
        {"Packs",
         [
           "The behavior harness now proves the shapes it used to skip: a real service manager booted as PID 1, a Docker daemon each case owns, iptables inside the namespace it writes, and a real dpkg database for install, remove, and autoremove.",
           "pfSense gains resolver, NTP, and WireGuard peer reads that never return their secrets, plus a DHCP reservation staged for the operator to apply."
         ]},
        {"Billing",
         [
           "A new subscription adopts the Paddle customer an owner's email already has instead of failing, and a repeating conflict now says which one it is."
         ]}
      ]
    },
    %{
      date: ~D[2026-08-08],
      slug: "a-vanished-runbook-a-deny-that-matched-nothing",
      title: "A vanished runbook, a deny that matched nothing, and a session that would not end",
      tag: "v0.38.0",
      summary:
        "A runbook too large to project answered as if it did not exist. That answer is reserved for an untrusted pack or a runner outside your scope, which have to stay indistinguishable from absence — but size is not that kind of fact, and folding it in meant list_runbooks quietly dropped the runbook while get_runbook denied one sitting in the operator's own console. It was reachable rather than theoretical. The budget is counted in bytes while the title and description limits counted characters, and a description at the documented 4,096-character limit encodes to 12,288 bytes in Japanese: writing your description in your own language was enough to make your runbook vanish. A size failure now reports its size, and those character limits carry byte bounds derived from the budget instead of assumed against it.",
      details: [
        {"Security",
         [
           "Ending a member's sessions now disconnects the session they are looking at, not just the cookie behind it. The disconnect asked for the addresses of sessions the same transaction had already deleted, found none, and left an open console working until the next navigation."
         ]},
        {"Console",
         [
           "A policy override that cannot match anything is flagged while you write it. The glob grammar treats every character except * as a literal, so an override written out of regex habit — cassandra\\.drop_* — validates, saves, and matches no action id that can exist. For a deny rule, that reads as protection the fleet does not have. The warning is advisory and never blocks: an override may legitimately name a pack you have not installed yet."
         ]},
        {"Website",
         [
           "Eight documentation and marketing links no longer render a stray space before the punctuation that follows them."
         ]}
      ]
    },
    %{
      date: ~D[2026-08-08],
      slug: "self-rotating-credentials-and-a-harder-execution-boundary",
      title: "Self-rotating runner credentials and a harder execution boundary",
      tag: "v0.37.0",
      summary:
        "A runner token now carries a 90-day life and refreshes itself two thirds of the way through, over the connection it already holds, so rotating a fleet credential no longer means going back to the host — and a token presented after its expiry is refused. The execution boundary tightened to match. Action children start with no_new_privs, so nothing a pack runs can pick up setuid or file-capability privileges the runner does not already hold, and an argument that resolves into the runner's own credential or state directory is refused before it reaches a shell. Reads that can hand back credentials wait for an approval now instead of being classified low risk, and signed dispatch signs the exact narrative a human approver reads.",
      details: [
        {"Security",
         [
           "Every runner token has a bounded life, including the ones minted before rotation existed. A token past its expiry is refused at connect, and the refresh happens over the existing connection with no host access.",
           "Reads that can return credentials are approval-gated rather than low risk, and the runner masks a run's sensitive values in a single pass, so one match cannot rewrite another's marker.",
           "MFA enrollment and recovery-code regeneration both require proof of the current inbox, and credential step-up codes are rate limited across the cluster rather than per node."
         ]},
        {"Runner",
         [
           "Action children start with no_new_privs, one symlink-containment walk covers every path the runner opens, and an action argument naming the runner's own state is refused before it reaches a shell.",
           "Upgrade note: because no_new_privs applies to the whole process tree, a setuid or setgid helper no longer elevates. If a non-root runner reached a resource through one — postqueue is setgid postdrop, which is how mailq reads the Postfix queue — give that runner user direct access instead, such as membership in the postdrop group.",
           "Every pack's curl is confined to an explicit protocol with globbing off, so a URL that arrives in an API response cannot expand into extra transfers or carry a credential to a host that response chose.",
           "An official multi-architecture container image is published at ghcr.io/andrewdryga/emisar-runner, with build provenance and an SBOM."
         ]},
        {"MCP",
         [
           "Signed dispatch signs the narrative a human approver actually reads (attestation v5), and the bridge verifies that narrative rather than a reconstruction of it. The signing key comes from a pinned credential directory instead of the environment.",
           "Runbook targets can name a runner group in the model contract, and an agent can revise and test a draft before a human publishes it."
         ]},
        {"Packs",
         [
           "The catalog now carries 95 packs and 1,498 actions, adding Apache Airflow, Spark, Google Cloud billing, and BunnyCDN.",
           "Every risky action in a modeled pack is now either proven by a behavior case against a real service or carries a declared reason it cannot be, and each pack's structured output is bounded to fit the runner's cap at its own advertised worst case."
         ]},
        {"Console",
         [
           "Runbook target selection scales to a real fleet: one stable trigger that names the chosen targets, a searchable roster of dense one-line rows, and scope icons that encode cardinality instead of infrastructure nouns."
         ]},
        {"Platform",
         [
           "The reads behind agent and console traffic got measurably cheaper. An action resolves from its own pack instead of the whole catalog, a catalog listing compares a stored descriptor digest instead of every descriptor column, and the keyset pages have the indexes their cursors need."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-31],
      slug: "staged-runbooks-and-hardened-enterprise-identity",
      title: "Staged runbooks and hardened enterprise identity",
      tag: "v0.36.0",
      summary:
        "A runbook can now carry a production operation from declared inputs to a staged result: typed inputs are bound once, stages run sequentially or in parallel against selected runner groups, steps extract named outputs, test success conditions, and wait within explicit bounds. An approval freezes the whole execution plan before any step begins, canonical JSON imports the same definition shape the console and MCP use, and the execution page shows each attempt and extracted value in order. Enterprise identity now gets the same fail-closed treatment: OIDC discovery and JWKS fetches stay behind a connect-time address policy, SCIM changes lock and reconcile the authority they act on, and names shown in runs and approvals are resolved only inside the account where the action happened.",
      details: [
        {"Security",
         [
           "OIDC discovery, JWKS refresh, and redirects are fetched through one bounded address policy that rechecks the document actually received; changing an issuer also clears credentials that belonged to the old one.",
           "SCIM bodies are bounded before authentication, group PATCH operations apply atomically in wire order, directory-owned suspensions can be reversed only by their owner, and disabling a connection retires the sessions and pending links it vouched for.",
           "Run and approval attribution now resolves a person's name through the membership in the action's account, so a profile from another workspace cannot leak into the audit surface."
         ]},
        {"MCP",
         [
           "The bridge and portal adopt the 2026-07-28 MCP routing headers and dual-era endpoint, including OAuth Client ID Metadata Documents for clients that use them.",
           "Release qualification names both required client models explicitly and requires Claude and Codex to pass the same held-out contract at the exact release commit; Gemini and Grok remain optional local evaluators."
         ]},
        {"Packs",
         [
           "The catalog now carries 91 packs and 1,386 actions, including bounded reads for GCP IAM, Monitoring, and Compute; Pure protection and performance history; Terraform state safety; Nomad job health; OIDC and JWKS; nftables; TCP; and Docker Compose.",
           "A missing source command or an HTTP 4xx or 5xx now fails the action instead of letting a downstream pipe or successful transport report an empty success, and registry installation preserves a pack script's executable bit."
         ]},
        {"Console",
         [
           "Runbook authoring uses type-aware inputs, compact target selection, explicit sensitive-output controls, one whole-run approval plan, and canonical JSON import instead of a parallel definition format.",
           "Execution pages follow the run detail's answer-first structure, with stages, attempts, output rows, waits, and terminal causes presented in execution order."
         ]},
        {"Website",
         [
           "Authentication and directory documentation now has one operator path across SSO, SCIM, account access, and the Okta, Entra, JumpCloud, Google Workspace, Keycloak, and generic OIDC guides, with one numbered step per provider screen."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-27],
      slug: "runner-identity-by-hostname-and-proven-pack-behavior",
      title: "Runner identity by hostname and pack behavior proven on real services",
      tag: "v0.35.0",
      summary:
        "A runner now identifies itself by its hostname: a reboot reconnects the same runner, a replaced ephemeral host enrolls as a new one, and no generated identity has to survive on disk for either to work — an explicit runner.id still overrides the default. Pack retention leaves a live fleet alone the same way: a version a connected runner still advertises is never swept, so a stable fleet keeps its pins and trust decisions through quiet weeks instead of losing them until the next reconnect. Behind the catalog, every behavior case now runs against its own disposable instance of the real service it targets, readiness is proven on the network path the case dials, and each high-risk action changed by the argument-boundary sweep carries a successful behavior case or a declared machine-readable risk exception.",
      details: [
        {"Packs",
         [
           "Behavior fixtures assume nothing they did not arrange: cases run as a non-root identity in a disposable service, the state a case asserts on is created by that case, and the snmp OSPF adjacency builds its network namespace on AppArmor-confined hosts, where the default container profile denies the mount.",
           "Readiness means the service a case will actually reach: ZooKeeper answers every four-letter word the suite uses before the first case starts, and databases that seed through a temporary boot-time daemon are probed on the routable address rather than loopback.",
           "The behavior matrix finishes in less than half the wall-clock time: a plan's images are pulled before its first case, slow suites shard across CI rows, and a plan whose service is heavy caps how many of its cases run at once."
         ]},
        {"Platform",
         [
           "The hosted admin runner bootstraps from a version-pinned release download with retries instead of asking the GitHub API which release is current, so an anonymous rate limit cannot keep a control-plane VM from starting.",
           "A production deploy re-plans when a manual apply has superseded its saved plan instead of failing the release."
         ]},
        {"Website",
         [
           "A clarity pass from founder review: the security page shows the signed-dispatch boundary at the point it acts, the home comparison states signed dispatch and the no-inbound-port posture in their own rows, case studies and comparisons read at the docs rhythm, and connect pages name the agent in the attribution line."
         ]},
        {"Also",
         [
           "Checks that used to run only in CI moved into the canonical gates — staticcheck into the Go gates, the Portal-only checks into the portal gate — so a green local gate and a green CI run mean the same thing."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-26],
      slug: "live-run-output-and-bounded-pack-arguments",
      title: "Live run output for agents and a tighter pack-argument boundary",
      tag: "v0.34.0",
      summary:
        "An agent waiting on a run now sees the output as it arrives: wait_for_run streams the run's event log through a scope-bound cursor, bounded by encoded bytes with oversized events fragmented, so a long action reports progress instead of going quiet until it finishes. Pack arguments gained a matching boundary — only finite choices and two-sided bounded numbers may render into a fixed shell program, while open-ended strings, paths, and arrays now travel as environment values or whole argv elements, and an authoring-time lint rejects a pack that breaks the rule. The documentation was rebuilt alongside both: terminal casts recorded from real CLI runs, a navigation split by the job you came to do, and pages corrected against the implementation.",
      details: [
        {"Security",
         [
           "The runner installers keep credentials off process argv. A GitHub token, an API key, and a device code used to ride the curl command line, where any local process could read them; they now travel as headers on standard input.",
           "Five pack arguments could pass a leading dash through to the target binary as an option. Their patterns now anchor the first character to a non-dash class, and pip_show terminates option parsing explicitly.",
           "Runbook creation never casts status, so a client-supplied \"published\" cannot mint published content; publishing at birth is its own transition gated on manage permission.",
           "Authorizer row-scoping fallbacks fail closed with an empty query rather than an unscoped one, and a Credo check keeps them that way. The runner's trust gate now refuses a run whose registered action has lost its pack.",
           "Bandit is patched for the WebSocket denial-of-service advisory, and OAuth registration rejects redirect URIs with no host or a fragment."
         ]},
        {"MCP",
         [
           "wait_for_run takes an output cursor and returns the next one, reading the event log forward within the caller's scope. The tail wakes on new progress rather than a row timestamp, and a finished run's trimmed output can still be paged back in.",
           "Pre-run dispatch rejections — contract changes, refusals, rate limits — log bounded, allowlisted fields, so a rejected call is visible in operations without putting model input in the log."
         ]},
        {"Packs",
         [
           "The loader rejects open-ended substitutions in fixed shell programs at authoring time, which turns a per-pack review habit into a check that runs in the gate.",
           "Curl-backed API actions fail on 4xx and 5xx responses instead of reporting transport success, and catalog metadata is validated against the same bounds the runner enforces.",
           "Risk tiers are consistent across the catalog: reload is high everywhere, scale is high everywhere. Behavior plans replaced generated cases, and pack compatibility matrices run in CI."
         ]},
        {"Console",
         [
           "Operator input survives a re-render. A half-written approval note, a chosen grant scope, a cleared runner-scope draft, and a partially typed policy override are no longer lost to a co-approver's broadcast or a refused submit.",
           "A pack-trust conflict names the runners that disagree about an action instead of failing generically, and run detail titles the terminal-cause panel by what actually happened.",
           "Subscription reconciliation pages through its work and isolates a failing row, and inactive runners are cleaned up on a schedule."
         ]},
        {"Website",
         [
           "The security page shows the approval loop as a console recording driven by a real run, not a mockup, and the docs carry terminal casts captured the same way.",
           "Documentation is reorganized by task: single sign-on and directory sync split apart, cloud and CLI agent connection split apart, containers separated into Kubernetes and Nomad with a host-install page, and operational limits and autoscaling fleets given their own pages.",
           "Body text reads at 16px on a capped measure, screenshots are cropped to the feature and open fullscreen, and an llms.txt index plus a Keycloak setup guide were added."
         ]},
        {"Also",
         [
           "Repository development tooling is consolidated behind one contributor command, and durable engineering knowledge moved into a single reviewed knowledge base."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-20],
      slug: "trust-aware-action-discovery-and-runner-re-enrollment",
      title: "Trust-aware action discovery and clean runner re-enrollment",
      tag: "v0.33.0",
      summary:
        "Action discovery now follows the runner's current pack trust: MCP catalog, search, exact lookup, and runbook recovery expose only complete manifests for exact versions an operator still trusts, while the console keeps an untrusted advertised action visible for diagnosis but locks Run with the reason. Dispatch rechecks the same contract, so revoking trust closes stale pages and tool calls too. Runner uninstall now removes the cached token while preserving local evidence, and a changed enrollment key re-registers the configured id or hostname automatically.",
      details: [
        {"Security",
         [
           "Pending, rejected, revoked, retired, hash-mismatched, and incomplete pack versions no longer enter model-visible discovery; trust failures stay on operator surfaces and in the audit trail.",
           "An advertised runner action whose exact pack version cannot dispatch remains visible for diagnosis, but Run is locked with the reason. Transaction-level dispatch revalidates trust so stale console state cannot execute.",
           "OAuth return targets survive SSO and registration, including the original query string, without accepting an external redirect."
         ]},
        {"Runner",
         [
           "Default uninstall removes the cached token and legacy token file while preserving configuration, local evidence, and logs; --purge still removes everything.",
           "A changed enrollment key re-registers the configured runner id or current hostname and replaces the cached token without an identity-reset prompt."
         ]},
        {"MCP",
         [
           "Catalog tools and runbook recovery fail closed when trust changes between inspection and execution without introducing the hidden pack version into model-visible results.",
           "ChatGPT tool annotations distinguish read-only calls from mutations, and domain verification accepts OpenAI's text challenge.",
           "Claude evals select MCP authentication by mode and skip interactive permission prompts during headless runs."
         ]},
        {"Also",
         [
           "A public incident-response skill gives customer agents a bounded observe, diagnose, act, and verify workflow.",
           "The Packs page follows the live catalog and gives unadvertised versions one day to disappear before cleanup."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-20],
      slug: "real-agent-evals-and-symptom-language-search",
      title: "Real-agent MCP evals and symptom-language action search",
      tag: "v0.32.0",
      summary:
        "Real agents now certify the MCP surface before it ships: a scheduled eval drives Claude and Codex through a fail-closed relay against a live stack and hard-fails on policy violations, invalid mutation arguments, dispatches without prior inspection, and placeholder run reasons — an API change that confuses a model now fails a build, not a customer. And search learned how operators actually talk: packs carry 562 phrases of operator vocabulary, ranking weighs rare words over common ones, and page-one recall on a symptom-language benchmark against the production catalog went from 46% to 100% — \"the db is slow\" finds the right postgres action on the first call.",
      details: [
        {"MCP",
         [
           "run_action takes an optional justification chain — evidence for what the agent observed, expected for the outcome it predicts — beside a reason that can now run to 2000 characters. Approvals and run details render the chain, so a reviewer sees the basis and the hypothesis, not just the request.",
           "Paginated reads hand back a copy-ready next call instead of a bare cursor; an agent continues a search by echoing one object.",
           "list_runners names each runner's dispatchable packs inline, answering what a named host can do in one call.",
           "Actions can opt into typed JSON results, dispatched against the pinned trusted descriptor."
         ]},
        {"Packs",
         [
           "A curated synonym map expands operator shorthand like db, mem, and k8s during search.",
           "The registry serves the catalog compact and gzip-encoded behind a CDN — about a tenth of the previous transfer.",
           "The Nomad Autopilot health action is fixed."
         ]},
        {"Runner",
         [
           "Runner access is explicit: a member is scoped to the runners and groups they may use, chosen in a clearer scope picker.",
           "A missing client binary travels as separate host readiness evidence: the action stays advertised for manifest verification and is simply not offered for dispatch."
         ]},
        {"Also",
         [
           "Empty runner onboarding points at installing a pack catalog instead of a run that cannot succeed.",
           "The ChatGPT connector's OAuth consent page renders correctly under its sandboxed CSP.",
           "Enterprise plans name their dedicated Slack support channel."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-17],
      slug: "installer-preserves-commented-zed-config",
      title: "The MCP installer preserves a commented Zed config",
      tag: "v0.31.1",
      summary:
        "Connecting Zed through the installer no longer drops to a manual step. Zed ships a settings.json with comments and trailing commas that the installer's strict JSON parser refused; it now adds the emisar server while keeping those comments, the trailing commas, and any servers already configured. The same comment-safe merge covers any editor that keeps a commented JSON config."
    },
    %{
      date: ~D[2026-07-17],
      slug: "browser-approved-connect-and-pack-lifecycle",
      title: "Browser-approved agent connect and pack lifecycle control",
      tag: "v0.31.0",
      summary:
        "Connecting a local agent no longer moves an API key by hand: the installer opens a browser approval, you approve the connection on a consent page, and per-client keys are written straight into the agent's config — the secret never touches the clipboard, shell history, or a process argument. And the pack catalog becomes something operators run, not just watch: delete a pack or a single version, revoke trust on a version, or let versions no runner advertises anymore age out on their own.",
      details: [
        {"Security",
         [
           "Five pack actions that could read a leading-dash value as a command flag are fixed, and their old versions retired.",
           "Three actions that dump container or process environment now require approval."
         ]},
        {"Runner",
         [
           "The runner CLI reloads the daemon on its own after a pack change.",
           "One upgrade step for self-hosted runners: rename the config key auth_key_env to enrollment_key_env and re-mint any keys that were never enrolled — connected runners keep working."
         ]},
        {"MCP", ["The same installer now sets up thirteen MCP clients."]},
        {"Packs",
         [
           "A runner still lagging on a version a security fix retired now reads as retired and points at the upgrade, instead of posing as an unknown pack asking to be trusted — approving it would have re-authorized the vulnerable bytes.",
           "Outdated packs show a quiet update-available hint.",
           "Nomad reaches 0.2.0 with deployment control and metadata-filtered discovery."
         ]},
        {"Console",
         [
           "Essential text on every marketing and console page is raised to WCAG AA contrast, kept there by a new check.",
           "Under-permissioned roles get a clean denial instead of a server error."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "database-enforced-tenant-isolation-and-steadier-dispatch",
      title: "Database-enforced tenant isolation and steadier dispatch",
      tag: "v0.30.0",
      summary:
        "Tenant isolation now lives in the database itself: every runner-owned child row carries a composite foreign key to its account, and CHECK constraints backstop the security-relevant enums — so a cross-tenant or out-of-range write is refused at the row, not just in application code.",
      details: [
        {"Security",
         [
           "Public pages and error responses carry the same Content-Security-Policy as the rest of the site.",
           "Sentry is disclosed as a subprocessor, with its events scrubbed of personal data before they leave.",
           "A runner that requires signed dispatch announces it over MCP."
         ]},
        {"Runner",
         [
           "A runner at capacity redelivers the dispatches it refused.",
           "The stale-dispatch sweep drains the oldest queued first, and stuck pending runs advance instead of stranding."
         ]},
        {"Console",
         [
           "Active sessions each render as their own row with their own address, sign-in time, and revoke.",
           "A retired pack's re-trust control no longer crashes the packs page.",
           "Faster run search on large accounts."
         ]},
        {"Platform", ["Direct paging for severe database and load-balancer alarms."]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "leaner-mcp-results-and-hardened-pack-catalog",
      title: "Leaner MCP results and a hardened pack catalog",
      tag: "v0.29.0",
      summary:
        "MCP results now meet LLM clients where they are: canonical string forms of integers and booleans coerce instead of failing the call, every rejected argument names its field and the JSON type it was sent as, and run summaries omit what carries no signal — streams that produced no bytes, completeness flags that are simply true, and per-stream digests — so a typical summary shrinks by a third.",
      details: [
        {"Security",
         [
           "Disabling two-factor authentication now demands a fresh step-up challenge.",
           "Production session cookies always carry the Secure flag."
         ]},
        {"Packs",
         [
           "Secret-dense config and environment dumps now require approval.",
           "Redis ACL password hashes are redacted from low-risk reads.",
           "Exec-style arguments reject a leading dash so a hostile value cannot be read as a flag."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "upgrade-safe-runners-and-honest-fleet-alarms",
      title: "Upgrade-safe runners and honest fleet alarms",
      tag: "v0.28.0",
      summary:
        "Runner upgrades now migrate the durable dispatch log across format and location changes instead of silently refusing every dispatch afterwards, and one broken installed pack degrades just that pack — named on the runner page and in MCP diagnostics with its load error — rather than crash-looping the whole runner.",
      details: [
        {"Security",
         [
           "Sign-in enforcement for SSO and MFA requirements covers every controller route.",
           "SCIM and other machine endpoints are rate-limited.",
           "Runner connections assert a TLS 1.2 floor."
         ]},
        {"Runner",
         [
           "An offline runner shows its real connection status instead of tamper-flavored trust alarms about a stale advertisement.",
           "The installer verifies dispatch state with the staged binary before touching a running service.",
           "emisar doctor explains a corrupt dispatch log, a degraded pack, and the last cloud rejection offline."
         ]},
        {"Platform", ["Direct alerts for database-down and no-healthy-backend conditions."]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "reliable-runner-startup-and-clearer-mcp-failures",
      title: "Reliable runner startup and clearer MCP failures",
      tag: "v0.27.0",
      summary:
        "Runner upgrades now use one final durable dispatch journal and refuse to connect when that state is corrupt, so a bad upgrade can't quietly half-run.",
      details: [
        {"Runner",
         [
           "Unsigned installations stay independent from signing state.",
           "Sensitive values are redacted from failure causes before they're reported."
         ]},
        {"MCP",
         [
           "Run summaries expose a bounded terminal failure message.",
           "Connector setup keeps key-bearing commands out of shell history.",
           "OAuth consent lets a person choose the account they intend to connect."
         ]},
        {"Platform",
         [
           "Newer non-destructive production plans supersede stale ones without adding a second approval gate."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "reconnect-safe-runs-and-clearer-agents",
      title: "Reconnect-safe runs and a clearer agents list",
      tag: "v0.26.0",
      summary:
        "When a runner drops its connection and comes back, the control plane recovers the runs that were in flight instead of stranding them, and the runner repairs any packs it kept across an upgrade before resuming work.",
      details: [
        {"Runner",
         [
           "Skips processes that were already cancelled.",
           "Reports a failed local audit honestly instead of masking it.",
           "Bounds the action catalog it advertises."
         ]},
        {"Console",
         [
           "The LLM agents list groups by the person behind each key and shows each connection's emisar-mcp bridge version inline, so an outdated bridge is obvious and one step from the upgrade command."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-16],
      slug: "stricter-runner-results-and-cleaner-settings",
      title: "Stricter runner results and cleaner settings",
      tag: "v0.25.4",
      summary:
        "The runner now rejects broken action contracts, invalid execution options, unchecked path targets, and out-of-range result metadata before those values cross the host boundary. Pack releases rebuild from the live registry history, and account settings drop redundant state labels."
    },
    %{
      date: ~D[2026-07-15],
      slug: "versioned-registry-schemas-for-append-only-publishing",
      title: "Versioned registry schemas for append-only publishing",
      tag: "v0.25.3",
      summary:
        "Pack Registry schema publishing now versions immutable JSON schema filenames and identifiers, so a changed catalog or action schema appends new objects instead of colliding with a prior release. The publisher still creates every immutable object before moving catalog pointers, and tests tie each schema identifier to its public object path."
    },
    %{
      date: ~D[2026-07-15],
      slug: "exact-action-validation-and-stronger-ui-proof",
      title: "Exact action validation and stronger UI proof",
      tag: "v0.25.2",
      summary:
        "Action arguments now keep numeric membership checks exact across the portal and runner, reject invalid allowed values before a pack or run proceeds, and validate the runner execution envelope instead of silently dropping malformed options. Contributor workflows also gain a frontier review preset, durable loop knowledge, a backlog drawer, and required before-and-after screenshot evidence for UI fixes."
    },
    %{
      date: ~D[2026-07-15],
      slug: "cleaner-setup-and-reliable-release-publication",
      title: "Cleaner setup and reliable release publication",
      tag: "v0.25.1",
      summary:
        "Runner and connector setup now keeps one-line commands compact, uses shorter Claude.ai instructions, and leaves transport diagnostics out of customer screens. Fleet examples distinguish supported from unsupported runners, account settings use quieter status labels, and release publication waits for the tagged commit's required CI result instead of losing a race. Runner argument parsing also accepts numeric strings only when they use valid JSON number syntax."
    },
    %{
      date: ~D[2026-07-15],
      slug: "durable-execution-and-native-mcp",
      title: "Durable execution and a tighter MCP boundary",
      tag: "v0.25.0",
      summary:
        "Runner execution now begins only after durable audit evidence and remains bound to the trusted pack, dispatch record, output digest, and terminal result.",
      details: [
        {"Runner",
         [
           "Cancelled process trees are contained, ambiguous paths and inexact numeric limits are rejected, and pattern-matched values stay redacted across log rotation."
         ]},
        {"MCP",
         [
           "The native MCP endpoint exposes twelve server-owned tools with bounded waits, crash-durable mutation recovery, and safer key promotion."
         ]},
        {"Platform",
         [
           "Coordinated installers, rollback-aware releases, multi-zone delivery, and clearer connector setup make the operating path easier to inspect."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-13],
      slug: "delivery-trust-and-mcp-discovery",
      title: "Stronger delivery controls and clearer trust evidence",
      tag: "v0.24.1",
      summary:
        "Delivery now rejects stale or incomplete plans, authenticates installer release metadata, narrows production credentials, and keeps published images and packs tied to tested bytes.",
      details: [
        {"Website",
         [
           "The Trust Center leads with current controls and a live DNSSEC chain.",
           "The official MCP Registry description explains emisar in plain language for people who discover it outside the website."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-12],
      slug: "release-integrity-and-pack-registry",
      title: "Hardened hosting, safer releases, and a public status page",
      tag: "v0.24.0",
      summary:
        "The hosted platform moved to hardened cloud infrastructure with zero-downtime rollouts, a private-network database, and independent external monitoring behind a public status page at status.emisar.dev.",
      details: [
        {"Packs",
         [
           "The pack registry serves from its own hostname, registry.emisar.dev, with anonymous access narrowed to exact object reads, generation-specific verification, and end-to-end tarball checks."
         ]},
        {"Platform",
         [
           "Portal releases publish the exact image exercised by CI.",
           "Binary releases are immutable and reproducible.",
           "Production plans queue in order without replacing an operator's pending review."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-07],
      slug: "recurrent-jobs-billing-sync-runner-install",
      title: "More reliable background work and a cleaner runner setup",
      tag: "v0.23.0",
      summary:
        "Routine product work is now more predictable: approval expiry, audit retention, billing sync, sign-in cleanup, and timed-out runs are handled by the control plane itself.",
      details: [
        {"Also",
         [
           "Billing contact sync keeps customer records tied to active account owners.",
           "Runner setup puts the install script details where operators need them."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-06],
      slug: "annual-billing-team-sso-security-hardening",
      title: "Annual billing, Team-owned SSO, and safer input handling",
      tag: "v0.22.0",
      summary:
        "Billing now supports monthly or annual checkout, shows recent invoices, and lets operators download invoice PDFs from the console. SSO moved into Team, where pending access requests, connection status, sign-in links, 2FA enforcement, and Require SSO live next to the roster.",
      details: [
        {"Security",
         [
           "Tightened handling of oversized directory-sync data, runner output, signup recovery, email changes, and account-scoped billing or runner actions."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-05],
      slug: "console-on-canvas-policy-and-pack-clarity",
      title: "A calmer, clearer console",
      tag: "v0.21.0",
      summary:
        "The console now uses one page language across fleet, agents, policies, packs, runbooks, billing, approvals, and audit — empty states explain the next useful action, dangerous actions share one confirmation dialog, machine identifiers are easy to copy, and navigation looks like navigation rather than a row of buttons.",
      details: [
        {"Console",
         [
           "Policies show what a rule allows, approves, or denies against the account's actual catalog.",
           "Pack search can narrow by risk tier or matching action."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-03],
      slug: "forensic-audit-and-decision-records",
      title: "Audit and approvals read like records",
      tag: "v0.20.0",
      summary:
        "The audit trail is easier to scan during an incident: each row makes the actor, target, action, and outcome clearer, and approval detail pages open with the decision state, then the command, arguments, reason, policy evidence, reviewer note, and timestamps in one record instead of scattered panels.",
      details: [
        {"Audit",
         [
           "SIEM export configuration moved to its own managers-only page, off the browse view."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-02],
      slug: "billing-checkout-mfa-and-shared-components",
      title: "Checkout, 2FA sign-in, and cleaner account forms",
      tag: "v0.19.0",
      summary:
        "Checkout now follows the selected plan, and billing-manager seats can manage billing without receiving broader admin powers. Accounts that require 2FA can challenge after a magic-link sign-in with TOTP or a recovery code.",
      details: [
        {"Console",
         [
           "Code entry, secret reveal, enrollment steps, switches, cards, and mobile list rows share the same console patterns, so repeated workflows feel familiar instead of rebuilt per page."
         ]}
      ]
    },
    %{
      date: ~D[2026-07-01],
      slug: "directory-owned-members-and-runner-scopes",
      title: "Directory sync owns directory-managed access",
      tag: "v0.18.0",
      summary:
        "Directory-managed members now behave consistently: synced roles stay owned by the IdP, deactivated users arrive suspended, manual suspensions are not undone by later syncs, and IdP-deactivated members cannot be reinstated from emisar.",
      details: [
        {"MCP",
         [
           "MCP keys can be limited by action and runner scope before a dispatch reaches a runner."
         ]},
        {"Console",
         [
           "Runner scope selection is clearer and reused across invitations and MCP keys."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-30],
      slug: "sso-setup-and-audit-retention",
      title: "SSO setup and audit retention become inspectable",
      tag: "v0.17.0",
      summary:
        "SSO setup now has dedicated connection pages with pending access requests, a test-connection step, synced users, sync health, and read-only provider fields after creation.",
      details: [
        {"Audit",
         [
           "Plan changes affect retention going forward rather than silently erasing existing rows.",
           "Exports record that they happened.",
           "Important identity, plan, retention, and action-run events carry the details an operator needs later."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-26],
      slug: "passwordless-signed-dispatch-and-pack-verification",
      title: "Passwordless sign-in, signed dispatch, and verified packs",
      tag: "v0.16.0",
      summary:
        "emisar now signs users in with magic links or SSO only. Email changes require a fresh verification step, and invite and confirmation emails carry sign-in links instead of asking for a password.",
      details: [
        {"Security",
         [
           "Signed dispatch gives runners a way to reject requests that were not made by a configured client."
         ]},
        {"MCP", ["MCP keys gained action scopes, expiry, kind labels, and rotation."]},
        {"Packs",
         [
           "The pack test harness expanded across the database, Kubernetes, routing, Nomad, and firewall packs."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-25],
      slug: "analytics-and-console-craft",
      title: "Product analytics and the console craft pass",
      tag: "v0.15.0",
      summary:
        "Server-side product analytics that set no tracking cookie: a weekly-rotating salted visitor id, scoped to marketing and growth, with no client SDK and the processor disclosed on /privacy, /trust, and /dpa.",
      details: [
        {"Security",
         ["Self-approval becomes a named policy mode: single-operator or four-eyes."]},
        {"Console",
         [
           "A console craft pass unifies the design system into one surface recipe, a dense-table width tier, shared empty states, and a single product term — the LLM agent; MCP is the protocol.",
           "Approvals gain a live expiry countdown and a per-card risk tier.",
           "The audit log goes on a logging diet, and mobile gets real operator cards."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-23],
      slug: "marketing-site-rebuilt",
      title: "The marketing site, rebuilt",
      tag: "v0.14.0",
      summary:
        "A ground-up rebuild of emisar.dev: a how-it-works walkthrough traces one real action through every gate with the actual payload, and an MCP reference, a procurement-ready Trust page, a Data Processing Addendum, and a Guides surface fill out the funnel.",
      details: [
        {"Website",
         [
           "The pack registry is searchable, and the changelog is data-driven with an RSS feed."
         ]},
        {"Platform",
         [
           "A roughly 1,590-test QA suite across portal, runner, and mcp.",
           "A marketing-honesty pass that cut every claim we could not back.",
           "Domain metrics for run outcomes, approvals, and billing."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-22],
      slug: "the-gate-design-system",
      title: "\"The Gate\": a new identity and design system",
      tag: "v0.13.0",
      summary:
        "emisar gets a face: a gate logo and custom wordmark, a single emerald brand token in place of the old indigo-and-emerald mix, a signature display typeface, and material depth from film grain, emerald glow, and glass elevation — with the gate device drawn into the hero from the logo.",
      details: [
        {"Console", ["The control plane moves onto the same brand token and type signature."]},
        {"Website",
         [
           "The marketing site is overhauled with a use-cases hub, a packs registry, a Trust page, ROI-tied pricing, and a WCAG AA contrast pass."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-19],
      slug: "security-review-and-datastore-packs",
      title: "Security-review hardening and the datastore pack wave",
      tag: "v0.12.0",
      summary:
        "A full security-review pass closes the sharp edges, and the datastore pack wave lands with it: CockroachDB, MongoDB replica-set lag, ClickHouse, Kubernetes and RKE2, Redis Sentinel, and SNMP.",
      details: [
        {"Security",
         [
           "A durable runbook-execution record ends a continuation ACL bypass.",
           "Pack trust fails closed, and the trusted pack hash is snapshotted at authorization.",
           "A cancelled approval-gated run can no longer be approved and delivered, and approval grants are consumed in the same transaction as the run.",
           "A privilege reduction disconnects the member's live sockets, and MFA verifies against the current secret under a row lock."
         ]},
        {"Runner", ["Live signing-key rotation over SIGHUP."]}
      ]
    },
    %{
      date: ~D[2026-06-17],
      slug: "signed-dispatch",
      title: "Bridge-attested signed dispatch",
      tag: "v0.11.0",
      summary:
        "End-to-end Ed25519 attestation on every dispatch: the MCP bridge signs each run_action frame, the portal relays the signature untouched, and an enforcing runner verifies it before executing — so a compromised control plane can relay a request but never forge one.",
      details: [
        {"Runner",
         [
           "The emisar keygen command mints the keypair; runners advertise enforcement, their trusted key IDs, and a maximum attestation age."
         ]},
        {"Console",
         [
           "The runners index shows a Signed-only chip, and a refused run is its own terminal state."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-17],
      slug: "tenancy-and-console-redesign",
      title: "Multi-tenant URLs and the console redesign",
      tag: "v0.10.0",
      summary:
        "Slug-based tenant URLs nest the app under a per-account path with a cross-slug tenant guard, SSO sign-in lands on the team's branded page, and a per-account require-SSO switch forces members through the account's IdP.",
      details: [
        {"MCP",
         ["Bridge hardening: response caps, oversized-frame resilience, and redirect refusal."]},
        {"Console",
         [
           "The console is rebuilt across five workstreams: nav regrouped into Operate, Fleet, and Settings; a single content-width scaffold; load errors that no longer read as empty; dead-end flashes that name the next move; and audit deep-links from every run, runner, and approval."
         ]},
        {"Platform", ["New Credo layer-boundary checks guard the architecture."]}
      ]
    },
    %{
      date: ~D[2026-06-16],
      slug: "sso-and-scim",
      title: "SSO, SCIM, and four-eyes approvals",
      tag: "v0.9.0",
      summary:
        "A configurable approval gate you set per policy: forbid self-approval and require a number of distinct approvers. OIDC single sign-on (Google Workspace, Okta, Keycloak) and SCIM 2.0 directory sync provision and deprovision from your IdP.",
      details: [
        {"Security",
         [
           "IdP groups map to emisar roles, and offboarding revokes a member's access and sessions automatically — with real-world interop for Okta header tokens and linking an IdP identity to an existing member."
         ]},
        {"Console",
         [
           "The shared component system fills out with typed-confirm dialogs, selects, checkboxes, and an accessibility pass."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-14],
      slug: "fleet-operability-and-operator-ux",
      title: "Fleet operability and the operator-experience overhaul",
      tag: "v0.8.0",
      summary:
        "Multi-machine clustering so dispatch and Presence span control-plane nodes, stale runs that re-dispatch to an online runner instead of stranding, and runbooks that honor a per-step runner target.",
      details: [
        {"Packs", ["The pack catalog reaches 73 packs and 1,096 actions."]},
        {"Console",
         [
           "A deep operator-experience sweep through runs, runbooks, approvals, the dashboard, team, and audit: streaming output, offline affordances, blast radius shown before dispatch, a live execution that rehydrates on refresh, recovery-code download, role-change confirms, and an escape hatch for an MFA lockout.",
           "The audit log gains actor, date-range, outcome, and free-text filters, and the first shared component system lands."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-12],
      slug: "runbook-engine-and-scoped-policy",
      title: "The runbook engine, scoped policy, and a reliability pass",
      tag: "v0.7.0",
      summary:
        "The runbook execution engine arrives with grouped targets, parallel waves, and a live results page, and policy gains per-runner and per-group overrides.",
      details: [
        {"Security",
         [
           "Approval expiry is enforced at decision time, pack trust is re-gated at approval, and the policy and grant audit commits in the same transaction as the run.",
           "Rate limits on the unauthenticated and MCP endpoints."
         ]},
        {"Runner",
         ["Runs stuck running on a dead runner now time out instead of hanging forever."]},
        {"Packs", ["An opt-in shell break-glass pack ships for staging."]},
        {"Platform",
         ["A top-to-bottom correctness, authorization-shape, and test-coverage pass."]}
      ]
    },
    %{
      date: ~D[2026-06-08],
      slug: "pack-expansion-and-hardening",
      title: "Pack catalog expansion, runbooks over MCP, and security hardening",
      tag: "v0.6.0",
      summary:
        "The catalog grows by fourteen packs (iscsi, multipath, bonding, frr, nic, victoriametrics, victorialogs, pfsense, traefik, tailscale, pure-flasharray, vector, typesense, zot), and emisar pack suggest recommends the ones a host actually runs.",
      details: [
        {"Security",
         [
           "An OAuth-consent privilege escalation closed, streaming output redacted across line boundaries, the script hash re-verified at exec time, and credentials streamed over stdin instead of argv."
         ]},
        {"MCP",
         [
           "Runbooks become readable over MCP through list_runbooks and get_runbook, so an agent can fetch a saved runbook and run it step by step."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-06],
      slug: "public-beta-control-plane",
      title: "Public beta control plane",
      tag: "v0.5.0",
      summary:
        "The hosted control plane opens: connect an MCP client, scope it to selected runners, and run a declared catalog behind policy — now on Elixir 1.20 and OTP 29.",
      details: [
        {"Website",
         [
           "The first marketing surface: comparison pages against SSH and a custom MCP server, the CSI data-loss use case, an animated home demo, and a zero-trust page mapping emisar to Anthropic's agent-safety framework."
         ]}
      ]
    },
    %{
      date: ~D[2026-06-03],
      slug: "remote-mcp-over-oauth",
      title: "Remote MCP over OAuth 2.1",
      tag: "v0.4.0",
      summary:
        "An OAuth 2.1 authorization server lets a remote MCP connector authenticate and scope itself to your runners.",
      details: [
        {"Runner",
         [
           "Runner identity becomes stable through a durable external id so re-registration is idempotent, and connection state moves to Phoenix Presence."
         ]},
        {"Packs", ["The emisar pack uninstall command and pack setup blocks."]},
        {"Console", ["A live badge surfaces packs waiting for a trust review."]},
        {"Platform", ["Sobelow and mix_audit scans in CI."]}
      ]
    },
    %{
      date: ~D[2026-06-02],
      slug: "pack-registry-and-install-cli",
      title: "The pack registry and install CLI",
      tag: "v0.3.0",
      summary:
        "The emisar pack install command pulls one hash-verified pack at a time instead of dumping the whole catalog, with a no-service flag for binary-only installs and install-time config baking so a runner boots without hand-editing. MCP tool calls now return the real result, including failures, rather than a bare status of sent."
    },
    %{
      date: ~D[2026-06-01],
      slug: "approvals-audit-control-set",
      title: "Approvals, audit, and the control set",
      tag: "v0.2.0",
      summary:
        "The pieces that make it safe to act: human approvals with revocable standing grants, a SHA-256 hash-chained host journal alongside a searchable cloud audit and NDJSON SIEM export, account-wide MFA with recovery codes, request idempotency, versioned runbooks, and per-runner billing through Paddle. The first action-pack library ships with it."
    },
    %{
      date: ~D[2026-05-31],
      slug: "the-foundation",
      title: "The foundation",
      tag: "v0.1.0",
      summary:
        "Where it began: an outbound-only on-host runner that advertises and executes a typed catalog, YAML action packs with typed argument validation, a risk-tiered default-deny policy engine, and an append-only audit trail. A JSON-RPC MCP server with tools/list and tools/call exposes the catalog to any agent, and a docker-compose dev stack plus single-use enrollment keys make it runnable in minutes."
    }
  ]

  @doc "All changelog entries, newest first."
  def entries, do: @entries

  @doc "An entry's grouped secondary changes — `[{group, [bullets]}]`, `[]` when summary-only."
  def details(entry), do: Map.get(entry, :details, [])

  @doc "Entry text flattened for the RSS description: the lead summary plus every grouped bullet."
  def full_text(entry) do
    grouped =
      Enum.map(details(entry), fn {group, items} -> group <> ": " <> Enum.join(items, " ") end)

    Enum.join([entry.summary | grouped], " ")
  end

  @doc "Display date, e.g. \"June 23, 2026\"."
  def display_date(%Date{} = date), do: Calendar.strftime(date, "%B %-d, %Y")

  @doc "RFC 822 pubDate for RSS, e.g. \"Tue, 23 Jun 2026 00:00:00 +0000\"."
  def rss_date(%Date{} = date), do: Calendar.strftime(date, "%a, %d %b %Y 00:00:00 +0000")

  @doc "Canonical URL for an entry (anchor on the changelog page)."
  def entry_url(%{slug: slug}), do: @base <> "/changelog#" <> slug
end
