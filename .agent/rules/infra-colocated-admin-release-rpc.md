# infra: trusted colocated administration reuses release RPC

**Rule.** When a private first-party runner is intentionally trusted with control of the portal host, its fixed action script invokes one bounded Elixir context entrypoint through the colocated release's `bin/emisar rpc`. A one-off pack uses the runner's existing argv/env contract; it never adds pack-specific metadata or behavior to the client-shipped runner. Do not add a private HTTP endpoint, callback credential, local listener, or custom transport just to enter the same BEAM.

**Why.** The release already owns authenticated Erlang distribution and the runtime context needed for administrative work. A second transport adds secrets, listeners, lifecycle ordering, parsing, and failure modes without creating a meaningful isolation boundary once the runner already has Docker or release-cookie authority. The pack can pass its schema-validated arguments through ordinary argv; changing the runner or reloading the action run adds no new trust boundary.

✅ Good — an immutable private-pack script passes schema-validated action arguments through ordinary argv and calls a single context boundary:

```sh
docker exec --env EMISAR_ADMIN_ACTION_ID=emisar.admin.account.show \
  emisar /app/bin/emisar rpc 'Emisar.Admin.execute(System.fetch_env!(...), args)'
```

The action run remains the durable audit and execution record; the RPC boundary dispatches the fixed private action without creating a second operation ledger.

❌ Bad — an internal-only Plug/Cowboy endpoint plus a second bearer token and Unix socket whose sole purpose is forwarding the same two identifiers into `Emisar.Admin`.

This rule applies only to an explicitly full-trust runner. Root access on the portal host and the Erlang release cookie are equivalent to portal control; document that fact and never describe this runner as sandboxed. A runner that must remain a real lower-trust boundary cannot use this pattern.

**Sweep target.** Private administration pack scripts and their COS startup path: runner changes used by only one pack, callback listeners, callback tokens, Unix sockets, ad hoc loopback HTTP routes, and duplicate operation tables.

**How it's enforced.** Review the runner diff when adding a private pack; it must remain empty unless a real customer-facing runner requirement exists. The infra template test executes the fixed script against a fake `docker exec ... bin/emisar rpc` and asserts cloud-init installs the pinned immutable runner release, writes the private pack, and starts the host process under systemd.
