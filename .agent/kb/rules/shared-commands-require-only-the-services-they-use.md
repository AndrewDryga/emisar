# Rule: A command requires only the services it uses

**Rule.** Discovery and requirement are separate steps. Read every workspace URL
Coop publishes without judging it, then require exactly the services the
command's own phases contact. A workspace legitimately holds a subset: Coop
shadows the Keycloak TLS key, so a box that was never granted it has no Keycloak
service at all, and a Portal gate that never speaks OIDC must still run.

In `tools/internal/devtool`, a command names its dependencies at the call site —
`a.up(ctx, needDatabase)` for the test and gate routes; ordinary `serve` and
`seed` require the database and configure Keycloak only when supplied. Full
`setup` and `doctor` require `everyDependency`. Readiness
waits follow the same set, so the DB-only routes wait for Postgres and nothing
else.

On a native host, reuse a reachable database at the URL Coop reports before
starting the stack. A healthy database-only test must not regenerate TLS files
or fail because restarting the unrelated Keycloak service requires mount approval.
Initial service startup still uses Coop; never invent a fallback URL or topology.

Absence is reported, never filled in:

1. Refuse by name. Say which service is missing, which `COOP_SERVICE_*` or
   `COOP_SERVE_URL_*` variable carries it, and how to start it. "Not every
   required URL was injected" tells the reader nothing they can act on.
2. Export nothing built around an empty URL. `"" + "/realms/emisar"` is not an
   issuer, and the seeds would have registered it as one. A variable whose
   service is absent stays unset.
3. Never invent a sidecar endpoint. When Coop loses a URL for a service
   that is genuinely running, that upstream bug must stay visible; supplying the
   real endpoint is the operator's explicit act, not the tool's inference.

Owned app listeners are different from sidecars: an unpublished Coop box uses
`http://localhost:4000` and `http://localhost:9091` for the Phoenix process it
starts itself. Supplied serve URLs still win. Host port publication is not a
prerequisite for an in-container browser, and an equal-port listener needs no proxy.

**Good.** `./run test portal` requires Postgres, waits for it, and runs with no
Keycloak URL in the environment. `./run doctor` in the same box refuses with
`this command needs Keycloak, and Coop injected no COOP_SERVICE_KEYCLOAK_URL`.

**Bad.** Validating all four URLs before knowing which command runs; disabling
TLS, weakening a check, or skipping tests to get past a missing service;
deriving a service URL from another variable so the gap stops showing.

**Enforced.** `./run gate tooling` runs the table-driven cases in
`tools/internal/devtool/workspace_test.go`, which cover the database-only load,
the strict full-workspace refusal, malformed and out-of-range URLs, and the
environment that omits absent services.

Related references: [keep Docker out of Coop boxes](shared-coop-box-gates-stay-docker-free.md),
[human development tooling is not agent state](shared-human-dev-tooling-is-not-agent-state.md),
and [solve the owned problem, not the general one](shared-solve-the-owned-problem.md).
