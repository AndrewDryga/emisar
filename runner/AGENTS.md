# runner — how we build (Go, on-host action runner)

The `runner` is the on-host binary that actually executes infrastructure actions. It dials **out** to the control plane over a websocket, receives `run_action` commands, **re-validates** every argument against the action schema it loaded locally, executes via `os/exec` (**argv arrays only — never a shell**), streams redacted output back, and journals every attempt to an append-only local JSONL log.

It is the most security-sensitive component in the repo: it runs commands on real hosts. Read the root `../AGENTS.md` (the creed) first — this file is the Go + runner specifics.

## The gate (verify before claiming done — creed #4)

A change is done only when this is green, run from `runner/`:

```
gofmt -l -s .                                       # zero output  (gofmt -w -s . to fix)
go vet ./...
go mod tidy && git diff --exit-code go.mod go.sum   # tidy must be a no-op
go test -race -count=1 ./...
```

Run the same gate from `mcp/` for that module. Linux-only behavior (Pdeathsig, `/var/log` symlinks) verifies in a Debian container — `docker build -f runner/docker/Dockerfile.test -t emisar-test runner/ && docker run --rm emisar-test`. Run each as a standalone command — never pipe `go test`/`gofmt` through `head`/`tail`; the pipe's exit code masks the tool's.

## Architecture (where things live)

Top-level files are the cobra CLI commands: `connect` (the long-running daemon), `pack`, `action`, `state`, `events`, `audit`, `version`. The work lives under `internal/`:

| Package | Owns |
|---|---|
| `internal/cloud/` | the outbound websocket client — connect loop, message (de)serialization, reconnect backoff |
| `internal/engine/` | the action pipeline: validate → clamp cloud opts → execute → redact → journal |
| `internal/executor/` | the `os/exec` wrapper — ctx cancellation, stdout/stderr streaming, SIGTERM→SIGKILL grace |
| `internal/packs/` | pack loader + in-memory registry (YAML parse, SHA-256 content hash) |
| `internal/validation/` | argument coercion + schema enforcement; path & duration validation |
| `internal/admission/` | the local allow/deny glob gate, compiled once at boot |
| `internal/redact/` | streaming output redaction (regex + named rules) |
| `internal/audit/` | append-only JSONL journal + cursor sidecar |
| `internal/config`, `internal/expressions`, `internal/hostscan` | config load; `{{ args.x }}` text substitution; host service detection |
| `pkg/actionspec`, `pkg/packspec` | pure shared types — no logic, importable by anything |

`docs/architecture.md`, `docs/wire-protocol.md`, `docs/security-model.md` (repo root) carry the boot sequence, wire message types, and validation invariants in full.

## Security posture (this binary runs commands on hosts)

Non-negotiable — runner's equivalent of portal's Iron Laws:

- **Never a shell.** Actions execute as `os/exec` argv arrays. Substitution is `{{ args.x }}` *text* replacement into argv/env only; the binary path is a literal from the pack YAML. No `sh -c`, no interpolation into a command line — ever.
- **Validate everything the cloud sends.** The only trusted input is the action *ID* (looked up in the local registry). Every argument is re-validated against the action's declared schema before execution — unknown args rejected, types coerced, defaults applied before evaluation.
- **Pack trust is pinned.** The cloud sends `expected_pack_hash`; re-hash the on-disk pack and refuse to run on mismatch. Never execute a pack the operator hasn't trusted.
- **Paths are contained.** Clean path args, check them against the allow/deny globs, block symlink traversal (`filepath.EvalSymlinks` + containment) — see `args_symlink_test.go`, `loader_symlink_test.go`.
- **Output is redacted on the way out**, line by line, before it leaves the host.
- **Least privilege.** Run as non-root where possible; installed packs are world-readable so a sudo-install stays readable to the service user.
- Every security-relevant decision has a `*_security_test.go` / `*_symlink_test.go` proving it. A change to validation / admission / redaction / exec **adds or extends one.**

## Go house style

- **Errors are values, wrapped with context.** `fmt.Errorf("loading pack %q: %w", name, err)` for chains (keep `%w` so callers can `errors.Is`/`As`); `fmt.Errorf("…: %s", v)` for leaf messages. `error` is the last return value. Structured domain errors (`*validation.Error` with `Arg`/`Code`/`Reason`) where a caller branches on the reason. No `panic` in core paths — only genuine invariant violations.
- **Structured logging only — `log/slog`.** No `fmt.Print*` / `log.Print*` for operational logs. `slog.LevelInfo` for normal flow, `slog.LevelWarn` for reconnects / recoverable errors. A component takes an optional `Logger *slog.Logger` in its options struct and defaults to `slog.Default()`.
- **Tests are stdlib + table-driven.** `t.Run(name, …)` subtests; `t.Helper()` on helpers; `t.TempDir()` for filesystem work (never write into the repo). **No testify, no new test deps.**
- **Concurrency: signal, don't block.** A coalescing wake-up is a buffered `chan struct{}` with a non-blocking `select { case ch <- struct{}{}: default: }`; a `sync.Mutex` guards per-request state; cancellation is a per-request `context.CancelFunc`. The connect daemon's loops (`senderLoop`, `heartbeatLoop`, `readvertiseLoop`) run independent of the socket lifecycle so in-flight actions survive a reconnect.
- **JSON is stdlib `encoding/json`** with `json:"snake_case,omitempty"` tags; protocol frames carry a `type` string field.
- **Small, single-purpose packages**, each named as one lowercase word. Pure types live in `pkg/`; anything with logic + dependencies lives in `internal/`. Match the surrounding file's style exactly.
- Toolchain is **Go 1.26.3** (`go.work`); deps are deliberately few (`coder/websocket`, `spf13/cobra`, `oklog/ulid`, `yaml.v3`). A new dependency on the host runner is new attack surface — justify it in one sentence, and prefer the stdlib.
