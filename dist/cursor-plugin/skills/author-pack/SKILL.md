---
name: author-pack
description: Author, validate, test, distribute, and certify a custom Emisar action pack for a customer fleet. Use when wrapping internal CLIs or services as declared actions, writing or reviewing pack/action YAML, testing a pack locally, rolling a pack out to runners, hosting a private pack registry with packctl, publishing a new pack version, retiring an unsafe version, or diagnosing pack trust and hash-mismatch issues.
---

# Author and ship a custom Emisar pack

Execute this workflow on the customer's environment. Do not require an Emisar
source checkout, fork, build toolchain, repository instructions, or internal
contributor skill. A pack is a directory of YAML the customer owns; author it
in their repo, prove it with the installed CLIs, and certify it through the
signed-in Emisar portal.

A pack is the contract between the operator and the LLM: it declares exactly
what may run on hosts, with what arguments, at what risk. Treat every action
you author as attack surface. Author restrictively, prove each claim, and
return one evidence-backed report.

## Use current public interfaces

Default to the hosted control plane at `https://emisar.dev`. Use a different
`EMISAR_URL` only when the operator identifies and trusts that deployment.

Verify commands and schemas before using them:

- Use `emisar pack --help`, `emisar action --help`, and `packctl catalog
  --help` as the installed-version contracts.
- `emisar pack validate` is the schema authority — it runs the exact loader
  and hash path the runner enforces. When validation disagrees with any
  document, including this one, the validator wins.
- Use the public guides at `https://emisar.dev/docs/publishing-packs`
  (authoring), `https://emisar.dev/docs/action-packs` (full YAML reference),
  `https://emisar.dev/docs/pack-registry` (self-hosted registries), and
  `https://emisar.dev/docs/mcp-reference` (MCP catalog contract).
- Use the signed-in portal's **Packs** page for trust decisions and each
  runner's **Advertised actions** for what the fleet actually serves.
- Study installed packs as worked examples: `emisar pack install <name> --dest
  ./examples` fetches a public pack you can read; pick one whose shape matches
  the job (exec reads, script actions, credentialed services).

Never reconstruct a YAML field, flag, or config shape from memory when the
validator, installed help, or a public reference can confirm it.

## Safety rules

- **The pack is a security boundary, not a convenience.** Every action you add
  is something an LLM may execute on hosts. When in doubt, narrow the action,
  raise its risk tier, or leave it out. Never loosen validation, lower a risk
  label, or widen `execution.inherit_env` to make a check pass.
- **Trust authority is a human decision, never yours.** Present the content
  hash, the diff, and your risk assessment; on hosted Emisar an account admin
  reviews the pending pack and clicks Trust in the portal. Do not press for
  approval, never click Trust, and never change which catalog the portal reads
  (step 6). Never call a pack trusted or certified until you have verified
  that exact hash is trusted for the account.
- **`emisar action run` executes locally and bypasses cloud policy and
  approvals.** Use it only for `risk: low` read actions, only on a
  development or staging runner, never on a production host. Prove mutating
  actions through the cloud path, where policy and approvals apply.
- Treat pack credentials, API tokens, and signing material as secrets. Secrets
  ride `execution.env` from the runner's protected environment file — never
  argv, never YAML literals, never stdout, never shell history. Mark secret
  args `sensitive: true`.
- Pack bytes are public to the fleet: hashed, advertised, and shown in the
  console. Nothing secret goes in a pack directory.
- If an action needs protected local files, sockets, groups, service control,
  or root, map it in `setup.host_access`. Name the exact actions, provide a
  persistent operator-run grant plus a verification command, and state the
  authority granted to the runner identity. Emisar displays these commands;
  it never runs them. Do not suggest action-time `sudo`: action children run
  with `no_new_privs` and cannot elevate that way.
- Keep publisher credentials off fleet hosts. `packctl` runs on a workstation
  or CI job; runners only ever fetch and verify.
- Pin installs with `--hash` everywhere past the first authoring host. Never
  install a pack whose content you have not validated or reviewed.

## 1. Scope the pack

Settle what the pack is for before writing YAML:

- The job: which service, CLI, or procedure the operator wants the LLM to
  handle, and the smallest action set that covers it. Prefer a few precise
  actions over a wrapper for every subcommand.
- The fleet: which runners get it, and how many hosts. A handful of hosts
  installs directly from a directory; a large fleet or CI-driven rollout
  wants a private registry (step 5).
- The authoring host: a development or staging runner where local proof is
  safe. Record `emisar --version` and `emisar pack list` there.
- The pack id: pick one that is not taken by the public catalog
  (`curl -fsS https://emisar.dev/packs.json` lists public ids) so registry
  installs never resolve ambiguously. Keep the directory in the customer's
  own git repo.

Collect required credentials for the wrapped service the same way the runner's
other packs do — named variables in the runner's protected environment file —
without echoing values.

## 2. Design each action before YAML

Decide these per action, and write them down — they become the YAML:

- **One action, one job, a searchable description.** The MCP catalog is what
  an LLM keyword-matches; open read descriptions with the verb of the job
  (List, Show, Get, Tail, Check), and make `description` a real doc string.
  List every file, network, and process side effect under `side_effects`.
- **Risk is honest.** `low` is reserved for pure reads and cheap bounded
  probes — it runs without approval. Anything that mutates state, opens a
  listener, binds a port, or can saturate a link is at least `medium`;
  destructive operations are `high`; unrestricted escapes are `critical`.
  Mislabeling a mutating action `low` bypasses the operator's approval gate.
- **The LLM never controls the command.** `execution.command.binary` plus an
  `argv` list is the shape; `{{ args.x }}` substitutes into fixed slots. The
  binary is a bare PATH-resolved name (`systemctl`, `psql`). When an action
  genuinely needs a pipeline, `/bin/sh` with a fixed `-c '<script>'` you
  author is acceptable. Pass open-ended strings, paths, and arrays through
  `execution.env` or as whole positional elements after the program
  (`["-c", "grep -- \"$1\" file", "emisar", "{{ args.pattern }}"]`).
  Only finite `enum`/`allowed` choices and numbers with both `min` and `max`
  may render into program text. An anchored regex constrains value shape; it
  is not a shell-isolation boundary.
- **Bound every argument.** Strings get `max_length` and an anchored
  `pattern` or an `enum`; numbers get `min`/`max`. An unbounded string is a
  DoS hole. **An anchored pattern is not path containment**: `.` and `/` are
  ordinary characters, so `^/var/log/myapp/.*` still matches
  `/var/log/myapp/../../etc/shadow`. A path the command reads or writes must
  declare `allowed_prefixes` (or `allowed_paths`/`denied_paths`) — that is
  what activates the runner's symlink-resolving containment.
- **A private pack may hardcode the fleet.** Unlike generic public packs,
  yours can enum the exact unit names, databases, and hosts it operates —
  tighter than any pattern. Use that advantage.
- **Design actions not to emit secrets.** No environment dumps, no
  credential-bearing connection strings, no unfiltered config reads.
  `output.redact` rules scrub known shapes as a fail-closed last line, but a
  secret no rule matches leaks — so don't print them in the first place.

## 3. Author the pack

The layout, from the authoring guide:

```text
my-pack/
  pack.yaml          # manifest: metadata + which action files to load
  actions/*.yaml     # one action per file
  scripts/*.sh       # only for kind: script actions
```

`pack.yaml` declares the pack; new packs start at `version: 0.1.0`:

```yaml
schema_version: 1
id: my-pack
name: My ops pack
version: 0.1.0
description: Short one-line summary shown on the runner and console.
vendor: acme
requires:
  os: [linux]
  binaries: [journalctl]
setup:
  host_access:
    - actions: [my.journal_tail]
      requirement: Read the system journal.
      recipes:
        - name: systemd Linux — default emisar service user
          commands:
            - sudo usermod -aG systemd-journal emisar
            - sudo systemctl restart emisar
          verify:
            - sudo -u emisar journalctl -n 1 --no-pager
          impact: The emisar service identity can read the complete system journal.
actions:
  - actions/journal_tail.yaml
```

Each action file is the full contract — this example shows the load-bearing
fields; the complete schema is in the YAML reference and the validator:

```yaml
schema_version: 1
id: my.journal_tail
title: Read recent system journal entries
kind: exec
risk: low
description: >
  Show the most recent system journal entries.
side_effects:
  - Reads the system journal.
  - Touches nothing.
args:
  - name: lines
    type: integer
    default: 100
    validation: { min: 1, max: 1000 }
execution:
  command:
    binary: journalctl
    argv: ["--no-pager", "-n", "{{ args.lines }}"]
  timeout: 10s
output:
  parser: text
  max_stdout_bytes: 65536
  max_stderr_bytes: 8192
examples:
  - title: Read the last 100 entries
    args: { lines: 100 }
```

Write every action this deliberately: designed bounds from step 2, honest
risk, honest side effects, an example an operator would recognize.

## 4. Validate, then prove it locally

On the authoring runner:

1. `emisar pack validate ./my-pack` — the same checks the runner runs at
   load. Fix until it reports `pack <id> OK` and record the printed `sha256:`
   content hash; that exact tuple is what the portal catalog matches or an
   account admin reviews.
2. `sudo emisar pack install ./my-pack` — copies it into the runner's packs
   dir and reloads the running daemon itself (no restart, no dropped runs).
3. `emisar action list` and `emisar action describe <id>` — confirm every
   action loaded with the intended risk, args, and bounds.
4. Prove one `risk: low` read locally: `emisar action run <id> --arg k=v
   --reason "pack authoring check"`. Local runs bypass the cloud, so this is
   strictly a development-runner debugging step — leave mutating actions for
   the cloud path in step 6.
5. Prove the bounds hold: rerun with an out-of-range value — a path outside
   `allowed_prefixes`, an oversized string, a number past `max` — and require
   a validation rejection, not an execution. An action whose denial you have
   not seen is unproven.
6. `emisar doctor` — confirm the runner still reports healthy, with required
   binaries present and env vars allowlisted.

## 5. Distribute it

**A few hosts — install the directory, pinned.** On each runner, install the
exact bytes you validated and reviewed; the install reloads the runner for you:

```sh
sudo emisar pack install ./my-pack --hash sha256:<validated hash>
```

Config management (Ansible, a base image) can drop the directory instead and
reload the runner. Either way every host runs identical, reviewed bytes.

**A fleet — host a private registry.** A registry is a static file tree over
HTTPS; anything that serves files can be one. It moves bytes only — the portal
still decides trust per account (step 6).

1. Get `packctl` on the publishing workstation or CI job (never fleet hosts).
   Build it from the same signed release tag your runners were installed from,
   so the tool that hashes a pack is the one whose loader will enforce that
   hash. Do not reach for `go install …@latest`: it pins nothing and builds
   whatever the default branch points at that minute.

   ```sh
   git clone --depth 1 --branch runner-v<version> \
     https://github.com/andrewdryga/emisar.git emisar-src
   cd emisar-src/runner && go build -o ~/.local/bin/packctl ./cmd/packctl
   ```

   Release tags are signed annotated tags, so `git verify-tag runner-v<version>`
   confirms the checkout before you build if you hold the signing key. Requires
   a Go toolchain; check `packctl --version`.
2. Build the tree. `--base-url` is wherever you will host it:

   ```sh
   packctl catalog build --packs ./packs --out ./dist \
     --base-url https://packs.acme.internal
   ```

3. Host it. GCS is native — immutable objects are precondition-protected and
   the pointers flip last:

   ```sh
   GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) \
     packctl catalog publish --dir ./dist --bucket acme-pack-registry
   ```

   S3, MinIO, or nginx: sync the files yourself — immutable objects first,
   then the two mutable pointers (`v1/suggest.json`, then `v1/catalog.json`)
   so a reader never sees a catalog referencing bytes that are not there yet.
4. Install fleet-wide, still hash-pinned:

   ```sh
   sudo emisar pack install my-pack \
     --registry https://packs.acme.internal --hash sha256:<reviewed>
   ```

   Or set `EMISAR_PACKS_REGISTRY=https://packs.acme.internal` once per host
   and use plain pack names; `my-pack=0.2.0` pins a version. `emisar pack
   update --dry-run` then reports fleet drift against your registry.

**Every rebuild after the first publish carries history forward.** Fetch the
currently-published catalog and pass it as `--previous` — this is what makes a
byte change to an already-published `id@version` fail the build (bump the
version instead) and keeps each pack's version history and retirement floor
intact. A rebuild without `--previous` silently starts history from empty:

```sh
curl -fsS https://packs.acme.internal/v1/catalog.json -o current.json
packctl catalog build --packs ./packs --out ./dist \
  --base-url https://packs.acme.internal --previous current.json
```

## 6. Trust it, then certify end to end

Trust is per account, and one deployment setting decides where it comes from:
the portal trusts an exact `pack@version/hash` on sight when that tuple appears
in the catalog it is configured to read (`EMISAR_PACK_CATALOG_URL`), and holds
every other hash pending with dispatch held. On hosted Emisar that catalog is
Emisar's published one, which your custom pack is not in — so it lands on the
**Packs** page as pending. An account admin opens it, compares the content hash
against the `pack validate` output you recorded, reviews the actions, and
clicks Trust; from then on that exact byte-for-byte version is the only one
authorized. Publishing to a registry confers no trust by itself. On a self-hosted
deployment whose owner separately configured the portal to read that catalog,
the exact tuple may be trusted after the portal observes it. The deployment
owner chooses that catalog — never reconfigure it to skip a review, and verify
the resulting trust state through `list_packs`.

So verify which state your pack is actually in before certifying anything, then
prove the whole chain through the customer's real MCP client:

1. `list_packs` with `availability: "all"` — the pack's exact version and
   hash appear as executable, with no descriptor or deployment issues. That is
   your trust verification: MCP does not expose pending, rejected, revoked, or
   retirement-blocked refs, so an absent ref sends you back to the portal's
   **Packs** page to see which one it is.
2. `find_actions` for the pack's job words — confirm the descriptions are
   discoverable the way an operator would ask.
3. `get_action` for one action — the returned schema matches the authored
   bounds, and the intended runner is listed compatible.
4. `run_action` with those exact refs, schema-valid args, and a clear reason,
   for a `risk: low` read; follow `wait_for_run` to terminal success. For a
   mutating action, dispatch through the same path and let policy and
   approval apply — an approval prompt reaching the operator is the system
   working; never work around it.
5. `recent_runs` — the run is attributed to this client, action, and runner,
   and appears in the account audit log.

**Lifecycle.** Any pack change bumps `version`, re-validates, re-deploys, and
earns trust again — the hash changes, so the new tuple is pending until an
admin reviews it, or trusted after the portal's configured catalog carries and
the portal observes that exact tuple. That is the drift guard working, not a
fault. On a security or critical fix — an under-bounded arg, a secret-emitting
read, a path escape, or a mislabeled risk — a version bump alone leaves
vulnerable copies runnable: also set `retired_below: <fixed version>` in
`pack.yaml` so runners still advertising older versions fail closed at
dispatch. Registry publishes enforce that floor
monotonically (with `--previous`). Routine changes never retire — operators
update at their own pace.

## Report

Use only these states: `PASS`, `DEGRADED`, `FAIL`, `SKIPPED` (name the
missing prerequisite and owner), `UNSUPPORTED`.

```text
Pack report - <pack id>@<version> - <UTC timestamp>
Overall: PASS | DEGRADED | FAIL | NOT CERTIFIED

Check                State       Evidence
design review        PASS        actions, risk tiers, bounds decided and recorded
validate             PASS        pack <id> OK, sha256:<hash>
local proof          PASS        <action id> ran + out-of-bounds arg rejected
distribution         PASS        <hosts or registry URL, hash-pinned>
trust                PASS        <hash> trusted for the account (admin review | exact configured-catalog tuple)
MCP functional       PASS        <action, runner_ref, run_id, terminal status>
audit                PASS        run attributed in recent_runs
lifecycle            PASS        version/retirement plan recorded

Shipped: <pack id>@<version>, sha256:<hash>, <n> actions, risk ceiling <tier>
Open items: <owner + exact next action, or none>
```

Overall is `PASS` only when every applicable check passes, including verified
trust — an untrusted pack is authored, not shipped. A required `FAIL` makes it
`FAIL`; a required `SKIPPED` makes it `NOT CERTIFIED`. Include exact ids,
versions, hashes, refs, run IDs, and sanitized errors; never credential
values or unredacted output.
