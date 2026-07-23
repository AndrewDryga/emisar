# Rule: shared development tooling lives outside agent state

**Rule.** A command used by both people and agents enters through the
repository's ordinary development surface (`dev/run` here), not through a
script hidden under `.agent/` or a project subdirectory. Reusable
implementations live under `tools/`; `.agent/` holds configuration, state, and
only narrowly project-owned agent-hook scripts, never another shared command
surface. Dependency Compose is
shared by host-native development and the agent box; application servers stay
outside that file when direct execution materially improves reload speed.
Repository tooling uses Go for reusable parsing and checks, Bash for thin
process/environment orchestration, and JavaScript only for browser automation.
Adding another tooling language requires deleting one or proving these three
cannot own the job. When multiple generators share an ignored output root such
as `dist/`, each generator owns a named subtree and cleans only that subtree.

**Why.** A human command hidden under agent state looks private, encourages a
second host-only implementation, and lets the two environments accumulate
different ports, services, and setup rules. One dependency topology plus one
command surface keeps their runtime contract identical without forcing a
hot-reload server through Docker filesystem boundaries.

**Good.** `dev/run serve` starts Phoenix directly and reads the workspace URLs
assigned to `dev/compose.yml`; `dev/run shot` delegates reusable Puppeteer logic
to `tools/browser/`; Coop points `box.compose` at the same dependency file;
pack registry builds replace `dist/packs/` without touching sibling artifacts.

**Bad.** `.agent/scripts/dev`, `portal/scripts/shot`, and `tools/browser/shot.mjs`
as separate public commands; host and box Compose files that describe the same
Postgres and Keycloak services with different ports; or one generator deleting
the shared `dist/` root before writing its own output.

**Sweep.** Search `.agent/` and project subdirectories for executable helpers,
search documentation for direct implementation paths that bypass
`dev/run`, and search all Compose files for duplicate dependency services before
adding a development command or sidecar. Search tooling manifests and shebangs
before introducing another language, and search cleanup commands for shared
output roots before adding a generator.

**Enforced.** Review and `dev/run check agent-setup` after agent configuration
changes; `dev/run check tooling` runs the same check in CI.
