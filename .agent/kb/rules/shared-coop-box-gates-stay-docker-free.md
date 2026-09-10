# Rule: Keep Docker out of Coop boxes

**Rule.** Docker access is intentionally unavailable inside a Coop box and stays
that way. Never mount a Docker socket, expose a daemon or proxy, start Docker in
Docker, or add privileges to make it work. A Docker client alone is useless
without that authority; access to the host daemon would let the agent escape the
box.

Keep the ordinary development loop inside the boundary:

1. Declare stable dependencies in `.agent/project.yaml` through `box.compose`.
   Coop starts those sidecars on the host before the box launches; code in the
   box reaches them through service DNS or the injected `COOP_SERVICE_*` URLs.
2. Keep focused checks and every canonical `./run gate <project>` runnable in the
   box without Docker. A gate may use a prepared sidecar, but it never starts or
   controls containers itself.
3. Run tests that create their own containers on a trusted host or in CI. Here
   that means pack behavior (`./run test packs`), host-access tests
   (`./run test pack-access`), end-to-end scenarios (`./run e2e ...`), and the
   packaged-stack smoke test (`./run smoke`). Record the result separately;
   never imply the box ran it.

This split keeps the fast path fast: run the smallest focused check while editing,
then the affected project gate in the box. Do not wait for a Docker-based test
when the change does not touch it. When container proof is part of acceptance,
keep the task open until the trusted host or CI result is available.

**Good.** Portal tests use the existing `db` and `keycloak` sidecars, then
`./run gate portal --changed` verifies the affected apps. A pack change gets its
authoring gate in the box and its behavior matrix on a trusted Docker host or CI.

**Bad.** Mounting `/var/run/docker.sock`, installing Docker and retrying, adding a
privileged Docker-in-Docker sidecar, skipping a project gate because Docker is
absent, or reporting an unrun container suite as green.

**Enforced.** Coop's isolation check treats a Docker socket in the box as a host
escape, and its sidecar validator rejects host sockets, privileged containers,
added capabilities, host namespaces, and escaping binds. `./run check
agent-setup` validates this rule and its index entry. Sweep `.agent/Dockerfile`,
`.agent/project.yaml`, Compose files, and `COOP_BOX` branches before adding a
tool or check that invokes Docker.

Related references: [Coop box builds are isolated](../coop-box-builds-are-isolated.md),
[every blocking check lives inside the canonical gate](shared-checks-live-in-the-canonical-gate.md),
and [CI decides what a workstation cannot](shared-ci-decides-what-a-workstation-cannot.md).
