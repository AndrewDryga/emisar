# runner — how we build (Go, on-host action runner)

The `runner` is the on-host binary that actually executes infrastructure actions. It dials **out** to the control plane over a websocket, receives `run_action` commands, **re-validates** every argument against the action schema it loaded locally, executes the pack-authored binary and argv via `os/exec`, streams redacted output back, and journals every attempt to an append-only local JSONL log. Fixed pack-authored shell programs keep open-ended values in environment or positional-argv data channels; only finite choices and two-sided bounded numbers may render into program text. The staging-only `shell` pack is the explicit break-glass exception.

It is the most security-sensitive component in the repo: it runs commands on real hosts. Read the root `../AGENTS.md` (the creed) first — this file is the Go + runner specifics.

## The gate (verify before claiming done — creed #4)

A change is done only when this is green from the repository root:

```
./run gate runner
```

It checks client-module boundaries and formatting, module checksums, `go vet`,
`staticcheck`, tidy-as-a-no-op, attestation parity against the bridge's copy,
race tests, a cross-build of every published platform, and the public
`install.sh` shell and behavior harness. The harness runs all fourteen
checks as root or through passwordless sudo; otherwise it runs eleven portable
checks and names the three privileged checks left to CI. Use
`./run test runner [go-test-args...]` for focused feedback; direct Go commands
are diagnostic, not final verification. Run `./run gate mcp` for that
module. Linux-only behavior (Pdeathsig,
`/var/log` symlinks) verifies in the Coop box from the repo root:
`coop run -- go -C runner test -race -count=1 ./...`. The box sees the real
`packs/` fixtures used by runner security contract tests without maintaining a
second toolchain image. Run each check as a standalone command — never pipe
`go test`/`gofmt` through `head`/`tail`; the pipe's exit code masks the tool's.

## Architecture (where things live)

Top-level files are the cobra CLI commands: `connect` (the long-running daemon), `pack`, `action`, `state`, `events`, `audit`, `signing` (the signed-dispatch group — `init` one-shot + `new-ca`/`new-cert`, all in `signing.go`), `version`. The root help groups these by category via cobra command groups (`Serve` / `Actions & packs` / `Diagnose & audit` / `Signed dispatch`) — a new top-level verb sets its `GroupID` in `main.go` (an ungrouped one falls to "Additional Commands"). The work lives under `internal/`:

**The host `emisar` binary ships operator verbs only.** Maintainer/publisher tooling lives in a separate `cmd/` binary in the **same module** ONLY when it technically must (today: `cmd/packctl`, the pack-registry `catalog build|publish`). New-verb test: *does a host need this?* No → it belongs in a `cmd/` binary, not the `emisar` root — so the host binary never links publisher-only surface (e.g. the GCS publish client, the whole `internal/catalog` build path) or handles a publisher token. Same *module*, not same *binary*, is what the hash constraint requires: publisher tooling must hash packs with the exact `internal/packs` loader the runner enforces, so it stays in-module (`go tool nm bin/emisar | grep internal/catalog` must be empty; the equivalent grep on `bin/packctl` is non-empty). It can't move to `tools/` either: Go forbids importing another module's `internal/`, and promoting the loader to `pkg/` to share it would make it public API self-hosters can depend on — in-module is the only shape that keeps the loader private AND byte-identical for publishing. `pack validate` stays in `emisar` — the loader is linked for install/daemon anyway, and operators validate third-party packs on hosts.

**This module (and `mcp/`) is a CLIENT-SHIPPED artifact — it carries NOTHING clients don't need.** Self-hosters install these binaries, build this code, and audit these `go.sum`s: every extra package here is bloat and attack surface in THEIR supply chain. Repo/CI/maintainer tooling — dependency gates, generators, e2e drivers, scripts — lives in the never-shipped **`tools/` module**, never here and never in `mcp/`. `packctl` is the ONE sanctioned in-module exception, and only because of the hash-parity constraint above; anything without such a hard technical requirement goes to `tools/`. Enforced mechanically by the first phase of `./run gate runner|mcp`, which asserts `runner/cmd` contains exactly `packctl` and `mcp/` has no `cmd/` at all — extending either list is a deliberate, reviewed act. It lives in the gate, not a CI step, so a green local gate cannot ship a red job.

| Package | Owns |
|---|---|
| `internal/cloud/` | the outbound websocket client — connect loop, message (de)serialization, reconnect backoff |
| `internal/engine/` | the action pipeline: validate → clamp cloud opts → execute → redact → journal |
| `internal/executor/` | the `os/exec` wrapper — ctx cancellation, stdout/stderr streaming, SIGTERM→SIGKILL grace |
| `internal/packs/` | pack loader + in-memory registry (YAML parse, SHA-256 content hash) |
| `internal/validation/` | argument coercion + schema enforcement; path & duration validation |
| `internal/admission/` | the local allow/deny glob + risk-ceiling gate, compiled once at boot |
| `internal/redact/` | streaming output redaction (regex + named rules) |
| `internal/audit/` | append-only JSONL security journal |
| `internal/config`, `internal/expressions`, `internal/hostscan` | config load; `{{ args.x }}` text substitution; host service detection |
| `pkg/actionspec`, `pkg/packspec` | pure shared types — no logic, importable by anything |

`.agent/kb/architecture.md`, `.agent/kb/specs/wire-protocol.md`, and
`.agent/kb/specs/security-model.md` (repo root) carry the boot sequence, wire
message types, and validation invariants in full.

## Security posture (this binary runs commands on hosts)

Non-negotiable — runner's equivalent of portal's Iron Laws:

- **No shell the cloud/LLM controls.** Actions run via `os/exec` — the binary + argv come literally from the pack YAML. Many actions' binary IS `/bin/sh` with a fixed `-c '<pipeline>'` program (for pipes, `${VAR:-default}`, etc.), but that program is authored, never cloud-supplied. The loader rejects open-ended strings, paths, arrays, and one-sided numeric args referenced in `-c` program text; authors pass them through `execution.env` or as whole positional argv elements after the program. Only finite `enum`/`allowed` choices and two-sided bounded numbers may render into fixed program text. A regex constrains an input's shape; it is not a shell-isolation boundary. The `shell` pack is the lone break-glass: there the operator supplies the whole command (arbitrary `/bin/sh -c`, `risk: critical`, default-denied).
- **Validate everything the cloud sends.** The only trusted input is the action *ID* (looked up in the local registry). Every argument is re-validated against the action's declared schema before execution — unknown args rejected, types coerced, defaults applied before evaluation.
- **Pack trust is pinned.** Packs are administrator-installed trusted content and system installs keep their trees root-owned; do not add descriptor-execution machinery for mutations that already require administrator access. The cloud sends `expected_pack_hash`; re-hash the on-disk pack and refuse to run on mismatch as pragmatic defense in depth. Never execute a pack the operator hasn't trusted.
- **Host readiness never rewrites descriptor identity.** Advertise the complete action descriptor set for manifest verification. Mutable host facts, such as a missing primary executable, travel separately and may only remove executable targets; never hide a descriptor or relax hash/manifest matching because a prerequisite is absent.
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
- Toolchain is **Go 1.26.6** (`go.work`); deps are deliberately few (`coder/websocket`, `spf13/cobra`, `oklog/ulid`, `yaml.v3`, and `santhosh-tekuri/jsonschema/v6` for typed `output.schema` result validation in `internal/outputschema`). A new dependency on the host runner is new attack surface — justify it in one sentence, and prefer the stdlib.
