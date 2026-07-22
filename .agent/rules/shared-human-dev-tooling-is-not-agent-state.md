# Rule: shared development tooling lives outside agent state

**Rule.** A command used by both people and agents lives in the repository's
ordinary development surface (`dev/` here), not under `.agent/scripts/`.
Dependency Compose is shared by host-native development and the agent box;
application servers stay outside that file when direct execution materially
improves reload speed. `.agent/scripts/` is reserved for agent enforcement,
bookkeeping, and orchestration mechanics.

**Why.** A human command hidden under agent state looks private, encourages a
second host-only implementation, and lets the two environments accumulate
different ports, services, and setup rules. One dependency topology plus one
command surface keeps their runtime contract identical without forcing a
hot-reload server through Docker filesystem boundaries.

**Good.** `dev/run serve` starts Phoenix directly and reads the workspace URLs
assigned to `dev/compose.yml`; Coop points `box.compose` at that same file.

**Bad.** `.agent/scripts/dev` for a command contributors also run, or separate
host and box Compose files that describe the same Postgres and Keycloak
services with different ports.

**Sweep.** Search `.agent/scripts/` for human-facing setup/server helpers and
search all Compose files for duplicate dependency services before adding a new
development command or sidecar.

**Enforced.** Review and `bash .agent/scripts/audit-llm-setup.sh` after agent
configuration changes.
