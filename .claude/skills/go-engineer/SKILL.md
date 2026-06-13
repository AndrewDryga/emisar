---
name: go-engineer
description: Engineer a change in the Go modules (runner/ or mcp/) the house way — read the project AGENTS.md first, match the Go house style (slog, fmt.Errorf %w, stdlib table-driven tests, no new deps), honor the runner's security posture, and run the gate. Use for any code change in runner/ or mcp/ (the Go analog of the portal Elixir skills).
effort: medium
argument-hint: "<what to change in runner/ or mcp/>"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Go engineering (runner / mcp)

The Go analog of the portal skills. The rules live in the project's `AGENTS.md` —
this skill is the *order of operations*, not a copy of them.

## 1. Read the project AGENTS.md first
`runner/AGENTS.md` or `mcp/AGENTS.md`, in full. They carry the gate, the package
layout, the security posture, and the Go house style. Don't work from memory —
the conventions are specific (e.g. the runner **never shells out**; argv only).

## 2. Wear the hats (root AGENTS.md creed)
- **Security** especially for `runner/` — it executes commands on hosts. Any
  change to validation / admission / redaction / exec **adds or extends** a
  `*_security_test.go`. Ask: what's the abuse case?
- PM / UX / Maintainer for the rest — smallest correct change, reads clearly later.

## 3. Match the house style
- Errors are values: `fmt.Errorf("…: %w", err)`; `error` is the last return.
- `log/slog` only (runner); stderr `fatalln` is fine for the tiny `mcp` bridge.
- Tests: stdlib + table-driven (`t.Run`, `t.Helper`, `t.TempDir`) — no testify.
- Small single-purpose packages; pure types in `pkg/`, logic in `internal/`.
- A new dependency is new attack surface — justify it in one sentence or use stdlib.

## 4. Run the gate (Definition of Done)
From the module dir (`runner/` or `mcp/`):

```
gofmt -l -s .
go vet ./...
go mod tidy && git diff --exit-code go.mod go.sum
go test -race -count=1 ./...
```

Linux-only runner behavior (Pdeathsig, `/var/log` symlinks): build + run `runner/docker/Dockerfile.test` — `docker build -f runner/docker/Dockerfile.test -t emisar-test runner/ && docker run --rm emisar-test`.
Show the output — never "should work". Don't pipe `go test`/`gofmt` through
`head`/`tail` (the pipe's exit code masks the tool's).

## 5. Close the loop
One focused commit → append to the project `.agent/LOG.md` (what + why) → tick the
task `[x]` in `.agent/TASKS.md`. Blocked? Mark it `- [B]` and add a
`PENDING_DECISIONS.md` entry. The commit-gate will gofmt-check your staged `.go`.
