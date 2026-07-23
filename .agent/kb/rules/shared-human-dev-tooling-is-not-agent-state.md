# Rule: shared development tooling lives outside agent state

**Rule.** A command used by both people and agents enters through the
repository's ordinary development surface (`./run` here), not through a
script hidden under `.agent/` or a project subdirectory. Reusable
implementations live under `tools/`; `.agent/` holds configuration, state, and
only narrowly project-owned agent-hook scripts, never another shared command
surface. Dependency Compose is
shared by host-native development and the agent box; application servers stay
outside that file when direct execution materially improves reload speed.
Shared repository tooling uses Go, including process orchestration and browser
automation. `./run` may contain only the minimal cached-binary bootstrap.
Development-only images, Compose fixtures, fake host assets, and test
configurations live under `dev/`; a product project's Dockerfile exists only
for an image the project intentionally supports as a shipped artifact.
Shell remains only where shell itself is the shipped artifact, container
entrypoint, or host-command fixture under test. Adding another tooling language
requires proving Go cannot own the job and documenting the runtime boundary.
Disposable screenshots and visual-audit output live under the owning task's
`screenshots/` directory. An agent with no active task creates and claims a
basic one before capturing, so task archive cleanup removes its evidence too.
Generated images that are committed as product or documentation assets stay in
their implementation-owned destination instead.
When multiple generators share an ignored output root such
as `dist/`, each generator owns a named subtree and cleans only that subtree.

**Why.** A human command hidden under agent state looks private, encourages a
second host-only implementation, and lets the two environments accumulate
different ports, services, and setup rules. One dependency topology plus one
command surface keeps their runtime contract identical without forcing a
hot-reload server through Docker filesystem boundaries.

**Good.** `./run serve` starts Phoenix directly and reads the workspace URLs
assigned to `dev/compose.yml`; `./run shot` enters the shared Go browser driver
and writes into its selected in-progress task;
Coop points `box.compose` at the same dependency file;
pack registry builds replace `dist/packs/` without touching sibling artifacts;
the Compose-only runner image and its fake host filesystem live under `dev/`.

**Bad.** `.agent/scripts/dev`, `portal/scripts/shot`, and a JavaScript browser
tool as separate command surfaces; host and box Compose files that describe the same
Postgres and Keycloak services with different ports; or one generator deleting
the shared `dist/` root before writing its own output; or a demo-only Dockerfile
under `runner/` that looks like a supported product image; or disposable
screenshots kept independently of the task that produced them.

**Sweep.** Search `.agent/` and project subdirectories for executable helpers,
search documentation for direct implementation paths that bypass
`./run`, and search all Compose files for duplicate dependency services before
adding a development command or sidecar. Search tooling manifests and shebangs
before introducing another language, and search cleanup commands for shared
output roots before adding a generator. Search product directories for
Dockerfiles that are consumed only by development Compose or test workflows.
Search for repository-global screenshot output and move each capture set into
its owning task.

**Enforced.** Review and `./run check agent-setup` after agent configuration
changes; `./run gate tooling` runs the same check in CI.
