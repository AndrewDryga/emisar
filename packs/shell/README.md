# shell — arbitrary shell (staging break-glass)

> ⚠️ **STAGING ONLY. Do not install this pack on production runners, and do
> not enable it in production.** This is the one capability emisar is built
> to avoid.

One action, `shell.run_script`, that runs an **arbitrary operator-supplied
shell script** on the runner host via `/bin/sh -c`. It bypasses the
declared-action model completely: whatever the script says, runs, as the
runner's user, with no per-argument schema and no allow/deny bounds beyond
the action timeout and output caps.

## Why it exists

So an agent can **verify a fix interactively on a staging host** — run the
command, see it work — before that fix is encoded as a proper *declared
action* or *runbook*. It is a scratchpad for getting a fix right, not a
substitute for a real action, and never a production tool.

## Why it's safe to *have* (and how it stays contained)

Shipping the pack changes nothing until an operator deliberately opts in, in
three steps:

1. **Install** the pack on a (staging) runner.
2. **Trust** its hash on the portal Packs page (the `pack_untrusted` gate).
3. **Open policy.** The single action is `risk: critical`, and the default
   account policy **denies** critical outright. It cannot run until you add a
   rule — keep it at `require_approval` (e.g. a `shell.run_script` override)
   so every run is human-gated.

On top of that, every invocation records the **full script text** in the
runner's local JSONL journal and the cloud audit log. Unlike handing an agent
SSH, there is a gate and a complete record.

## Keep it least-privileged

The script runs as the **runner's service user**. Run that user with the
least privilege the staging task needs — the action can do anything the user
can. Privilege is the runner's config, never an argument the agent controls.

## Install (staging only)

```sh
emisar pack validate packs/shell
emisar pack install packs/shell    # on a STAGING runner, on purpose
```
