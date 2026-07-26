# Every blocking check lives inside the canonical gate

**Rule.** A check that can fail a pull request runs *inside* `./run gate
<project>`, and CI reaches it by invoking that gate — never by running the tool
itself in a workflow step. When a workflow calls a linter, scanner, or validator
directly (`run: mix sobelow`, `go install staticcheck@… && staticcheck ./...`),
move it into the gate and delete the step in the same change.

The narrow exception is a check that genuinely cannot run on a workstation
because it needs the CI environment itself: a fresh network advisory feed
(`govulncheck`, Trivy), a built release image, cross-compilation for platforms
the contributor does not have, or credentials that only CI holds. Those stay as
workflow steps — and stay honest about it, because each one reintroduces the
gap below.

**Why.** `./run gate` is the Definition of Done (creed #4): an agent or
contributor takes it green and commits. A check that lives only in CI makes that
promise false — the gate passes on a tree the job rejects, so the failure is
discovered after the push, by someone who has already moved on. Worse, it
accumulates silently: a job that only runs when its paths change can sit unseen
for weeks. `tools/` reached **forty** `ST1005` findings and one dead function
behind a green `./run gate tooling` because staticcheck was a CI-only step,
while `runner/` and `mcp/` — checked by the same step — stayed clean by luck of
what changed. The same gap hid the Portal dependency audit, the Phoenix security
scan, and the compile-cycle budget.

**✅ Good** — the gate owns the check; CI runs the gate.

```go
// tools/internal/devtool/gates.go
if err := a.run(ctx, dir, nil, "go", "run", staticcheckVersion, "./..."); err != nil {
    return fmt.Errorf("%s staticcheck findings: %w", module, err)
}
```

```yaml
- name: Run canonical module gate
  run: ./run gate "$target" --coverage coverage.out
```

**❌ Bad** — the workflow is the only place the check exists, so a green local
gate still fails the job.

```yaml
- name: Run canonical module gate
  run: ./run gate "$target"

- name: Run staticcheck
  run: |
    go install honnef.co/go/tools/cmd/staticcheck@2026.1
    staticcheck ./...
```

Pin the tool version in the gate the same way the workflow pinned it, and invoke
it with `go run <module>@<version>` so it never becomes a thing the contributor
must install first.

**How it's enforced.** Review signal, and a mechanical one: any `run:` step in
`.github/workflows/ci.yml` that invokes `mix`, `go`, `staticcheck`, `sobelow`,
or another checker directly, rather than `./run …`, is either a gate hole or one
of the environment-bound exceptions above — and the exceptions carry a comment
saying which. Sweep target: `grep -n '^\s*run:' -A3 .github/workflows/ci.yml`
and read every step that is not a `./run` call.
