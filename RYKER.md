# RYKER.md

Written by Ryker from `162c018` on 2026-09-27.

## Purpose

Emisar lets operators and MCP-capable AI agents run declared infrastructure actions through policy, approvals, and an audit trail. This repository contains the Phoenix control plane, an outbound-only Go host runner, the MCP bridge and CLI, action packs, customer integrations, and production infrastructure.

## Components

- [portal/](portal/) — Elixir/Phoenix umbrella containing the control plane, operator console, public website, and remote MCP API.
- [portal/apps/emisar/](portal/apps/emisar/) — Domain contexts, authorization, Ecto persistence, recurrent jobs, and the bundled pack catalog.
- [portal/apps/emisar_web/](portal/apps/emisar_web/) — HTTP controllers, LiveView screens, runner WebSocket, MCP/OAuth endpoints, and marketing pages.
- [portal/config/](portal/config/) — Compile-time and runtime application configuration.
- [portal/rel/](portal/rel/) — Release commands and overlays used to migrate and start the deployed application.
- [runner/](runner/) — Go host daemon and operator CLI that validate, execute, redact, and journal infrastructure actions.
- [runner/internal/](runner/internal/) — Runner transport, execution engine, pack loading, argument validation, admission, redaction, and audit implementations.
- [runner/pkg/actionspec/](runner/pkg/actionspec/) — Shared action descriptor types that define the action schema.
- [runner/pkg/packspec/](runner/pkg/packspec/) — Shared pack manifest types.
- [runner/cmd/packctl/](runner/cmd/packctl/) — Registry builder and publisher using the runner's exact pack loader and content hashing.
- [mcp/](mcp/) — Standard-library-only Go MCP bridge and direct CLI, including client setup, credentials, and signed dispatch.
- [packs/](packs/) — Versioned YAML action packs with scripts, service fixtures, and semantic behavior tests.
- [infra/](infra/) — Terraform production stack for Google Cloud networking, compute, database, IAM, secrets, DNS, and monitoring.
- [skills/](skills/) — Public customer skills for installation, client connection, pack authoring, and incident response.
- [dist/](dist/) — Tracked integration packages alongside ignored generated distribution artifacts.
- [dev/](dev/) — Development container images, service configurations, demo fixtures, and integration-test harnesses.
- [docker-compose.yml](docker-compose.yml) — Packaged local topology with Portal, demo data, runners, MCP, and signing services.
- [run](run) — Root contributor entry point that bootstraps and invokes the Go development tooling.
- [tools/](tools/) — Separate Go module for contributor commands, CI, browser tooling, tests, and release operations.
- [.tool-versions](.tool-versions) — Exact Erlang, Elixir, Go, Terraform, and TFLint versions for development and CI.
- [.github/workflows/](.github/workflows/) — Validation, Portal delivery, component releases, pack behavior tests, and MCP certification workflows.
- [.agent/kb/](.agent/kb/) — Repository architecture, interface contracts, engineering rules, and operational runbooks.

## Build, test and run

- `./run help` — Lists the contributor command surface; run commands from the repository root unless stated otherwise. From [README.md](README.md).
- `./run bootstrap` — Prints setup instructions and toolchain pins; works before Go is installed. From [README.md](README.md).
- `coop build` — Builds the pinned development image; the recommended host setup requires Coop and Docker. From [README.md](README.md).
- `coop run -- ./run setup` — Sets up sidecars, dependencies, migrations, and browser tooling through the Coop environment. From [README.md](README.md).
- `coop shell` — Enters the development box. From [README.md](README.md).
- `asdf install` — Installs the pinned native toolchains after the required asdf plugins are available. From [run](run).
- `./run setup` — Validates prerequisites and prepares the local application and dependency services without seeding demo data. From [portal/README.md](portal/README.md).
- `./run doctor` — Reports installed prerequisite versions and actionable mismatches. From [README.md](README.md).
- `./run certs trust` — Trusts the workspace development certificate on macOS; run once after setup. From [portal/README.md](portal/README.md).
- `./run seed` — Explicitly installs idempotent demo data, including the demo owner and runner enrollment key. From [portal/README.md](portal/README.md).
- `./run serve` — Starts Phoenix with live reload at the workspace URL. From [README.md](README.md).
- `./run urls` — Prints workspace-specific Portal, metrics, PostgreSQL, and Keycloak URLs. From [README.md](README.md).
- `./run smoke` — Starts the slower packaged Compose topology at localhost:4010. From [README.md](README.md).
- `./run check changed` — Runs quick checks for changed files. From [portal/README.md](portal/README.md).
- `./run test portal --stale` — Runs stale Portal tests for focused feedback. From [portal/README.md](portal/README.md).
- `./run test portal --failed` — Reruns previously failed Portal tests. From [portal/README.md](portal/README.md).
- `./run gate portal --changed` — Checks changed Portal sources and runs affected application tests. From [portal/AGENTS.md](portal/AGENTS.md).
- `./run gate portal` — Runs the complete Portal compile, formatting, static analysis, security audits, tests, and test-output guard. From [portal/AGENTS.md](portal/AGENTS.md).
- `(cd runner && go build -o ../bin/emisar .)` — Builds the host runner and operator CLI. From [runner/README.md](runner/README.md).
- `./run gate runner` — Checks Go formatting, dependencies, static analysis, attestation parity, race tests, cross-builds, and installer behavior. From [runner/AGENTS.md](runner/AGENTS.md).
- `(cd mcp && go build -o ../bin/emisar-mcp .)` — Builds the local MCP bridge and direct CLI. From [mcp/README.md](mcp/README.md).
- `./run gate mcp` — Checks Go quality, the standard-library-only dependency rule, attestation parity, tests, and supported-platform builds. From [mcp/AGENTS.md](mcp/AGENTS.md).
- `./run gate packs` — Validates packs, hash goldens, the generated catalog, and focused Portal catalog tests; does not execute actions. From [packs/AGENTS.md](packs/AGENTS.md).
- `./run test packs redis` — Executes Redis pack behavior cases against disposable Compose services. From [dev/README.md](dev/README.md).
- `./run test pack-access` — Tests declared host-access grants and protected-resource behavior on disposable hosts. From [.github/workflows/ci.yml](.github/workflows/ci.yml).
- `./run gate infra` — Runs credential-free Terraform formatting, initialization, validation, TFLint, and cloud-init checks. From [infra/README.md](infra/README.md).
- `./run gate tooling` — Runs the required gate for executable contributor and agent tooling changes. From [AGENTS.md](AGENTS.md).
- `./run gate all` — Runs the repository-wide verification gate. From [AGENTS.md](AGENTS.md).
- `./run check agent-setup` — Checks contributor guidance, skill discovery, metadata, KB indexing, and hook policy. From [AGENTS.md](AGENTS.md).
- `./run check docs` — Checks documentation; required alongside agent-setup for manuals, skills, or KB-only changes. From [AGENTS.md](AGENTS.md).

## Deploy and release

- Pull requests to main run selected validation jobs under a read-only token; Required - CI combines their results into the required check. From [.github/workflows/ci.yml](.github/workflows/ci.yml).
- Each main push invokes CI from the same commit. CD loads and publishes the tested Portal image to GHCR by immutable digest, with provenance and the CI-produced SBOM. From [.github/workflows/cd.yml](.github/workflows/cd.yml).
- Pack changes or registry drift trigger serialized publication after CI. The publisher builds against the live catalog and writes immutable artifacts plus live registry pointers. From [packs/PUBLISHING.md](packs/PUBLISHING.md).
- CD creates a provisional HCP Terraform configuration and saved production plan using that commit's Portal image digest; required pack publication must finish first. From [.github/workflows/cd.yml](.github/workflows/cd.yml).
- Review the intended commit, resource changes, and image digest in HCP Terraform, then use Confirm & Apply. GitHub does not apply infrastructure. From [.agent/kb/runbooks/deployment.md](.agent/kb/runbooks/deployment.md).
- The release entry point migrates before boot under Ecto's advisory lock. Verify rollout health, readiness, sign-in, runner reconnections, registry output, and cluster state. From [.agent/kb/runbooks/deployment.md](.agent/kb/runbooks/deployment.md).
- Prepare a product release by updating portal/VERSION, the website changelog, license date, relevant tests, and catalog; run the required gates and certify Claude and Codex against the exact release commit. From [.agent/kb/runbooks/release.md](.agent/kb/runbooks/release.md).
- Create and verify a signed annotated vMAJOR.MINOR.PATCH tag at the release anchor, push it, and publish matching GitHub release notes. Published release tags remain immutable. From [.agent/kb/runbooks/release.md](.agent/kb/runbooks/release.md).
- Runner and MCP binaries use separate signed runner-vX.Y.Z and mcp-vX.Y.Z tags targeting current main. Update Portal compatibility versions and Compose pins before tagging; trusted workflows publish verified artifacts and GitHub mirrors. From [.agent/kb/runbooks/deployment.md](.agent/kb/runbooks/deployment.md).
- The hosted MCP Registry listing is reconciled from protected main by schedule or manual dispatch and follows the live deployed product version rather than the product tag alone. From [.github/workflows/mcp-registry-release.yml](.github/workflows/mcp-registry-release.yml).
- Rollback uses another reviewed saved plan selecting a previous immutable image digest. Database changes are not reversed, so confirm that the older image supports the current schema. From [.agent/kb/runbooks/deployment.md](.agent/kb/runbooks/deployment.md).

## Conventions

- Read the root and touched project's AGENTS.md plus relevant KB rules before editing; CLAUDE.md and GEMINI.md point to the canonical manual. From [AGENTS.md](AGENTS.md).
- Keep changes focused, reuse existing shapes, and avoid speculative abstractions or unnecessary dependencies. From [AGENTS.md](AGENTS.md).
- Validate untrusted input and preserve authorization, account isolation, pack trust, audit, redaction, and denial coverage. From [AGENTS.md](AGENTS.md).
- Use ./run for contributor checks and finish with the relevant project gate; distinguish local validation from publication and live verification. From [AGENTS.md](AGENTS.md).
- Preserve unrelated work, stage only owned changes, use the current checkout, and allow only one agent to write, gate, or commit at a time. From [AGENTS.md](AGENTS.md).
- Claim implementation work through Coop; completion includes green gates, a focused commit with a Coop-Task trailer, updated task records, and closing the task. From [AGENTS.md](AGENTS.md).
- Coop-box gates stay Docker-free; Docker-backed integration work belongs in an environment with the required host services. From [AGENTS.md](AGENTS.md).
- Portal contexts own authorization: check Subject permissions before database access and scope queries to the subject immediately before fetching. From [portal/AGENTS.md](portal/AGENTS.md).
- Keep queries in Query modules, schemas limited to data shape, changesets pure, and public context returns tagged. From [portal/AGENTS.md](portal/AGENTS.md).
- Authorize every LiveView event and MCP/controller action; changed context behavior needs happy-path, denial, and cross-account tests. From [portal/AGENTS.md](portal/AGENTS.md).
- Never edit or delete production-applied migrations; add a new migration. Run the complete Portal gate before pushing or releasing. From [portal/AGENTS.md](portal/AGENTS.md).
- Go code uses contextual error wrapping, slog, standard-library table-driven tests, and minimal dependencies; maintainer tooling belongs in tools. From [runner/AGENTS.md](runner/AGENTS.md).
- The runner revalidates arguments and pack hashes, contains paths, redacts output before transmission, and requires regression tests for security decisions. From [runner/AGENTS.md](runner/AGENTS.md).
- Keep MCP tool behavior and catalogs server-owned; preserve the bridge's standard-library-only boundary and byte-identical attestation implementations in MCP and runner. From [mcp/AGENTS.md](mcp/AGENTS.md).
- Pack changes need behavior tests as well as validation, appropriate version bumps, and regenerated catalog artifacts in the same commit. From [packs/AGENTS.md](packs/AGENTS.md).
- Pack shell programs are authored and fixed; bound inputs, declare helper binaries, contain file paths, and assign risk from actual impact. From [packs/AGENTS.md](packs/AGENTS.md).
- Infrastructure stays private by default with least-privilege IAM and protected stateful resources; secret values enter through sensitive HCP workspace variables. From [infra/AGENTS.md](infra/AGENTS.md).
- Open an issue for significant changes, keep PRs small, explain tradeoffs, and update tests and documentation for behavior changes. From [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Respect the Apache versus BSL licensing split and any required CLA; review AI-assisted work and disclose material assistance when requested. From [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Do not include secrets or confidential material in contributions, and report vulnerabilities through the security process rather than public issues. From [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Where to look

- Understand architecture, contracts, and operational procedures: [.agent/kb/README.md](.agent/kb/README.md)
- Add or change domain behavior and authorization: [portal/apps/emisar/lib/emisar/](portal/apps/emisar/lib/emisar/)
- Add a database migration: [portal/apps/emisar/priv/repo/migrations/](portal/apps/emisar/priv/repo/migrations/)
- Find domain test fixtures: [portal/apps/emisar/test/support/fixtures/](portal/apps/emisar/test/support/fixtures/)
- Change operator console screens: [portal/apps/emisar_web/lib/emisar_web/live/](portal/apps/emisar_web/lib/emisar_web/live/)
- Reuse or change shared UI components: [portal/apps/emisar_web/lib/emisar_web/components/](portal/apps/emisar_web/lib/emisar_web/components/)
- Change public website copy and customer documentation: [portal/apps/emisar_web/lib/emisar_web/controllers/marketing_html/](portal/apps/emisar_web/lib/emisar_web/controllers/marketing_html/)
- Find HTTP routes and endpoint ownership: [portal/apps/emisar_web/lib/emisar_web/router.ex](portal/apps/emisar_web/lib/emisar_web/router.ex)
- Inspect the published MCP schema contract: [portal/apps/emisar_web/priv/mcp/api-schemas.json](portal/apps/emisar_web/priv/mcp/api-schemas.json)
- Change runner validation and execution behavior: [runner/internal/engine/](runner/internal/engine/)
- Change MCP stdio transport: [mcp/main.go](mcp/main.go)
- Author an action pack: [packs/AGENTS.md](packs/AGENTS.md)
- Write semantic pack behavior cases: [dev/test-packs/README.md](dev/test-packs/README.md)
- Build or publish the pack registry: [packs/PUBLISHING.md](packs/PUBLISHING.md)
- Inspect the catalog bundled with Portal: [portal/apps/emisar/priv/packs/catalog.json](portal/apps/emisar/priv/packs/catalog.json)
- Change contributor commands and gates: [tools/internal/devtool/](tools/internal/devtool/)
- Change which CI checks run for a diff: [tools/internal/ci/select.go](tools/internal/ci/select.go)
- Deploy or roll back Portal: [.agent/kb/runbooks/deployment.md](.agent/kb/runbooks/deployment.md)
- Cut a product or component release: [.agent/kb/runbooks/release.md](.agent/kb/runbooks/release.md)
- Change production infrastructure or investigate recovery procedures: [infra/README.md](infra/README.md)
