# Host access recipes map exact actions

**Rule.** An operator must be able to tell which actions need extra host authority and
how to grant only that authority before enabling them. Free-form setup notes do
not provide that contract.

For every action that needs a protected file, local socket, service identity,
group, ACL, capability, polkit rule, or root, declare `setup.host_access` in
`pack.yaml`:

- `actions` lists the exact action IDs the grant enables. One action appears in
  at most one host-access group.
- `requirement` names the protected resource or operation.
- each named recipe provides complete `commands`, a `verify` command that runs
  as the runner identity, and an `impact` statement naming the authority that
  identity receives.
- the grant is persistent across both the target daemon recreating its socket
  or log and the runner restarting. Configure the resource creator, a durable
  service hook, or a persistent group/policy; a one-shot ACL on a recreated
  path is not a recipe.

**Why.** The commands are display-and-copy text. Neither the runner nor the Portal
executes, interpolates, or silently adjusts them.

The runner sets `no_new_privs` on action children. An action cannot use `sudo`,
a setuid/setgid helper, or a file capability to acquire new authority. Grant
the runner service identity direct narrow access, or use a mediated service
boundary such as polkit/D-Bus. If root is genuinely unavoidable, show the exact
service override and say plainly that every action child from that runner
service receives root authority. If a recipe uses group membership, account
for `execution.user`: explicitly selecting an action user replaces the
supplementary groups inherited from the runner service.

**How it's enforced.**

The Go pack validator rejects empty fields, unsafe control text, duplicate
action assignments, and action IDs outside the pack. The catalog preserves
commands byte-for-byte; the runner CLI and public pack page render them as
code. `./run gate packs` checks the structural contract and requires one
pack-owned proof for every exact recipe. `./run test pack-access [pack-name]`
runs the published commands on a disposable systemd host, first proves the
mapped protected-resource operation is denied, then reruns it under the
restarted runner identity with `no_new_privs`. Ordinary pack behavior cases
separately prove the action against its real service; host-access client stubs
never count as provider behavior.
