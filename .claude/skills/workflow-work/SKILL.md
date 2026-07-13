---
name: workflow-work
description: Execute an approved emisar plan step-by-step, using the touched project's AGENTS.md gate between steps and avoiding scope creep. Use when implementing a planned change, working through a checklist, or the user says "go"/"implement it"/"do the plan". Stops and reports on the first red gate.
effort: high
argument-hint: "[plan, or 'continue']"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Work the plan

Implement one step at a time. The point is a green, reviewable change — not speed.
If there's no plan yet and the change is non-trivial, run `/workflow-spec` first. Read root
`AGENTS.md` and the `AGENTS.md` for every touched project before editing.

## The loop (per step)

1. **State the step** in one line so progress is visible (a `TaskUpdate` if a task
   list exists).
2. **Build it in the standard shape.** Use the narrower skill when one exists:
   `/elixir-new-context` or `/elixir-context-fn` for portal contexts, `/go-engineer` for
   runner/mcp, `/security-engineer` for trust boundaries, `/design-frontend` for HEEx,
   `/elixir-testing` for ExUnit coverage. If you're unsure a function, option, or flag
   exists — yours or a dependency's — `/tooling-verify-api` before you write it; don't
   guess (prime directive #7).
3. **Gate before moving on.** Use the touched project's gate:
   - **portal/** — after each `.ex`/`.exs` edit, run `mix credo <file>` from
     `portal/`; step gate with compile/format plus focused tests; final gate below.
   - **runner/** or **mcp/** — `gofmt -l -s .`, `go vet ./...`, `go mod tidy &&
     git diff --exit-code go.mod go.sum`, `go test -race -count=1 ./...`.
   - **packs/** — `emisar pack validate packs/<name>` for each touched pack; update
     redis/cassandra portal hash golden when those packs change.
   - **infra/** — `terraform fmt -check -recursive`, `terraform init -backend=false
     && terraform validate`, `tflint --init && tflint`.
   - **agent tooling/docs** — run the changed script plus
     `bash .agent/scripts/audit-llm-setup.sh`.
4. **Red gate → stop.** Don't pile the next step on a broken one. Fix it, or report
   the blocker with the error and your read on it. Never edit a test to make a real
   failure pass.

## Rules while working

- **No scope creep.** Build the approved slice. A good idea that wasn't in the plan
  → note it as "later", don't build it now. If the plan turns out wrong, stop and
  re-plan with the user — don't silently redesign.
- **Readable + no bloat (prime directive).** Match the surrounding style. Delete
  dead code you pass. No speculative options/abstractions. Comments say *why*.
- **Tests are part of the step, not a follow-up.** A portal write isn't done
  without its denial + cross-account tests (§7); runner/mcp/packs changes need the
  security/validation regression their project manual requires.
- **Greenfield (IL-11).** Changing a not-yet-shipped migration → edit it in place.
  Replacing code → delete the old, update callers, in this change.

## Finish (IL-20 — verify before claiming done)

Run every touched project's final gate exactly as written in its `AGENTS.md`.
For portal, that is:

```sh
cd portal && mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test
```

For agent/tooling changes, include `bash .agent/scripts/audit-llm-setup.sh`.
Then **show the output** and give a plain status: what's done, what's verified,
what's left. If something is unverified, say so — don't say "should work". Offer
`/review-ship` or `/review-board` before the PR when risk warrants it.
