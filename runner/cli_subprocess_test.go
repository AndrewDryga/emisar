package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The runner's main() builds the full cobra tree and calls os.Exit(1) on any
// command error (main.go:55-58). The root dispatch, --version/-h short-circuits,
// the unknown-command/flag rejections, the boot/config fatals, and `audit
// verify`'s os.Exit(1) chain-break path therefore can't be exercised
// in-process. We re-exec the test binary with a sentinel env var so the child
// runs main() with controlled args/env; the parent asserts on its stdout /
// stderr / exit code. This is the stdlib pattern (see os/exec's own
// TestHelperProcess, and mcp/main_startup_test.go) and the only way to automate
// the CLI-surface rows the test plan deferred as "needs a subprocess harness".
//
// The VERSION VCS lines (RUN-030 T02/T03) are special: a `go test` binary
// carries no buildvcs settings, so the sentinel can't observe them. Those two
// rows use a real `go build` with controlled -buildvcs flags (buildRunner).

const runMainSentinel = "EMISAR_RUNNER_RUN_MAIN"

// TestMain dispatches into main() when the sentinel is set; otherwise it runs
// the package's tests normally.
func TestMain(m *testing.M) {
	if os.Getenv(runMainSentinel) == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

// runCLI re-execs this test binary so the child runs main() with the given args
// + extra env. It returns stdout, stderr, and the process exit code. The
// environment is minimal — the sentinel plus an empty EMISAR_CONFIG so a real
// /etc/emisar/config.yaml (or a developer's $EMISAR_CONFIG) can't perturb the
// boot-fatal assertions — plus whatever the caller passes.
func runCLI(t *testing.T, args []string, env map[string]string) (stdout, stderr string, exitCode int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = []string{
		runMainSentinel + "=1",
		"EMISAR_CONFIG=",      // never auto-discover a config off the host
		"HOME=" + t.TempDir(), // and never the per-user well-known path
		"PATH=" + os.Getenv("PATH"),
		// Under CI's -coverprofile the re-exec'd child is coverage-instrumented
		// and warns "GOCOVERDIR not set" on stderr, breaking every stderr-empty
		// assertion. Point it at a scratch dir (the child's coverage is discarded
		// on purpose — the parent's profile is the one that counts).
		"GOCOVERDIR=" + t.TempDir(),
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	err := cmd.Run()
	exitCode = 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exitCode = ee.ExitCode()
		} else {
			t.Fatalf("running child: %v", err)
		}
	}
	return outBuf.String(), errBuf.String(), exitCode
}

// writeRunnableConfig writes a minimal valid config wiring the journal under
// dir and a one-action pack (id "<pack>", action "<pack>.ping" running
// echo) the deny list can target. Returns the config path. denyPing adds an
// admission denylist entry for the ping action.
func writeRunnableConfig(t *testing.T, dir string, denyPing bool) string {
	t.Helper()
	packRoot := filepath.Join(dir, "packs")
	packDir := filepath.Join(packRoot, "linux")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatalf("mkdir pack: %v", err)
	}
	manifest := "schema_version: 1\nid: linux\nname: linux\nversion: 0.0.1\ndescription: d\nactions:\n  - actions/ping.yaml\n"
	action := "schema_version: 1\nid: linux.ping\ntitle: Ping\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\n" +
		"execution:\n  command:\n    binary: echo\n    argv: [\"hi\"]\n  timeout: 5s\n  timeout_min: 1s\n  timeout_max: 30s\n" +
		"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"
	if err := os.WriteFile(filepath.Join(packDir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write pack.yaml: %v", err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "actions", "ping.yaml"), []byte(action), 0o644); err != nil {
		t.Fatalf("write action: %v", err)
	}

	cfgPath := filepath.Join(dir, "config.yaml")
	cfg := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"paths:\n  packs:\n    - " + packRoot + "\n  data_dir: " + filepath.Join(dir, "data") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n"
	if denyPing {
		cfg += "admission:\n  deny:\n    - linux.ping\n"
	}
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return cfgPath
}

// --- RUN-001 — root dispatch, version/help, unknown command/flag -----------

// `emisar --version` / `-v` print the version line and exit 0. Cobra's default
// version template renders `emisar version <Version>` (Use + "version" + the
// Version field). The flag short-circuits before any command runs, so stderr
// stays clean.
func TestCLI_VersionFlagPrintsVersionExitsZero(t *testing.T) {
	for _, flag := range []string{"--version", "-v"} {
		stdout, stderr, code := runCLI(t, []string{flag}, nil)
		if code != 0 {
			t.Errorf("%s: exit = %d, want 0; stderr=%q", flag, code, stderr)
		}
		if !strings.Contains(stdout, Version) {
			t.Errorf("%s: stdout = %q, want it to contain the version %q", flag, stdout, Version)
		}
		if stderr != "" {
			t.Errorf("%s: a version short-circuit writes nothing to stderr, got %q", flag, stderr)
		}
	}
}

// `emisar` with no subcommand prints the root help (the root has no RunE) and
// exits 0; `--help`/`-h` do the same. The help lists the command tree, so the
// commands an operator can reach can't silently drift.
func TestCLI_NoArgsAndHelpPrintRootHelpExitZero(t *testing.T) {
	for _, args := range [][]string{nil, {"--help"}, {"-h"}} {
		name := "no args"
		if len(args) > 0 {
			name = args[0]
		}
		t.Run(name, func(t *testing.T) {
			stdout, stderr, code := runCLI(t, args, nil)
			if code != 0 {
				t.Errorf("exit = %d, want 0; stderr=%q", code, stderr)
			}
			// The help must enumerate the subcommands (the operator's map of the
			// CLI) and the category headers that group them.
			for _, want := range []string{
				"Usage:", "connect", "pack", "action", "audit", "doctor", "events", "signing", "state", "version",
				"Serve:", "Actions & packs:", "Diagnose & audit:", "Signed dispatch:",
			} {
				if !strings.Contains(stdout, want) {
					t.Errorf("root help missing %q:\n%s", want, stdout)
				}
			}
		})
	}
}

// An unknown subcommand is rejected: cobra writes `error: unknown command ...`
// to stderr exactly once (SilenceUsage + SilenceErrors keep main's single print
// from being doubled, main.go:37-58) and the process exits 1. closes
// ,.
func TestCLI_UnknownCommandExitsOneSingleError(t *testing.T) {
	stdout, stderr, code := runCLI(t, []string{"frobnicate"}, nil)
	if code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr, "unknown command") || !strings.Contains(stderr, "frobnicate") {
		t.Errorf("stderr should name the unknown command, got %q", stderr)
	}
	if n := strings.Count(stderr, "error:"); n != 1 {
		t.Errorf("the error must be printed exactly once (not doubled), got %d: %q", n, stderr)
	}
	if stdout != "" {
		t.Errorf("an unknown command prints nothing to stdout (SilenceUsage), got %q", stdout)
	}
}

// An unknown global flag is rejected with a single error on stderr, exit 1.
func TestCLI_UnknownGlobalFlagRejected(t *testing.T) {
	// On the root and on a subcommand: both reject the unknown flag.
	for _, args := range [][]string{{"--bogus"}, {"version", "--bogus"}} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			stdout, stderr, code := runCLI(t, args, nil)
			if code != 1 {
				t.Errorf("exit = %d, want 1", code)
			}
			if !strings.Contains(stderr, "unknown flag") || !strings.Contains(stderr, "--bogus") {
				t.Errorf("stderr should reject the unknown flag, got %q", stderr)
			}
			if n := strings.Count(stderr, "error:"); n != 1 {
				t.Errorf("the error must be printed exactly once, got %d: %q", n, stderr)
			}
			if stdout != "" {
				t.Errorf("nothing should reach stdout, got %q", stdout)
			}
		})
	}
}

// --- RUN-001 — each subcommand dispatches to the right RunE -----------------

// Every read-only subcommand routes through main()'s cobra tree to its own
// RunE and exits 0 on success. This drives the real binary (not an isolated
// sub-command) so the AddCommand wiring + arg routing can't silently drift —
// each command produces output recognizably its own.
func TestCLI_EachSubcommandDispatches(t *testing.T) {
	dir := t.TempDir()
	cfg := writeRunnableConfig(t, dir, false) // a one-action linux.ping pack
	// Seed a 1-event chain so `audit verify` has a real intact log to walk.
	if _, _, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "seed"}, nil); code != 0 {
		t.Fatalf("seeding the audit chain failed: exit=%d", code)
	}

	cases := []struct {
		name     string
		args     []string
		wantOut  string // a substring proving the right RunE ran
		onStderr bool   // some commands print their result to stderr
	}{
		// action describe prints the actionspec.Action struct, whose fields carry
		// no json tags → PascalCase keys ("ID", not "id").
		{name: "version", args: []string{"version"}, wantOut: "emisar " + Version},
		{name: "action list", args: []string{"--config", cfg, "action", "list"}, wantOut: "linux.ping"},
		{name: "action describe", args: []string{"--config", cfg, "action", "describe", "linux.ping"}, wantOut: `"ID": "linux.ping"`},
		{name: "pack list", args: []string{"--config", cfg, "pack", "list"}, wantOut: "linux"},
		{name: "state", args: []string{"--config", cfg, "state"}, wantOut: `"runner_state"`},
		{name: "events cat", args: []string{"--config", cfg, "events", "cat"}, wantOut: "linux.ping"},
		{name: "audit verify", args: []string{"--config", cfg, "audit", "verify"}, wantOut: "chain intact"},
		{name: "signing new-ca", args: []string{"signing", "new-ca"}, wantOut: "public_key"},
		// `doctor` and `connect` are intentionally omitted: doctor exits non-zero
		// here (no cloud/token to satisfy its preflight checks — its dispatch is
		// covered by TestDoctorCmd_* in-process), and connect needs a live socket.
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, code := runCLI(t, c.args, nil)
			// doctor exits non-zero when it can't reach a cloud; this config has
			// no cloud.url, so its checks pass and it exits 0.
			if code != 0 {
				t.Fatalf("%v: exit = %d, want 0; stderr=%q", c.args, code, stderr)
			}
			out := stdout
			if c.onStderr {
				out = stderr
			}
			if !strings.Contains(out, c.wantOut) {
				t.Fatalf("%v routed to the wrong command or produced no output; want %q in:\nstdout=%q\nstderr=%q",
					c.args, c.wantOut, stdout, stderr)
			}
		})
	}
}

// the global `--json` flag is honored only by commands that
// branch on it. Driven through main() so the real persistent-flag parsing is
// exercised: `version --json` ignores it (still the human text line, no JSON),
// while `action list --json` honors it (a JSON array, not the table header).
func TestCLI_JSONFlagHonoredOnlyWhereBranched(t *testing.T) {
	cfg := writeRunnableConfig(t, t.TempDir(), false)

	t.Run("version ignores --json", func(t *testing.T) {
		stdout, stderr, code := runCLI(t, []string{"version", "--json"}, nil)
		if code != 0 {
			t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
		}
		if !strings.Contains(stdout, "emisar "+Version) {
			t.Errorf("version --json must still print the human line:\n%s", stdout)
		}
		if strings.Contains(stdout, "{") || strings.Contains(stdout, "[") {
			t.Errorf("version must not emit JSON; --json is a no-op there:\n%s", stdout)
		}
	})

	t.Run("action list honors --json", func(t *testing.T) {
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "list", "--json"}, nil)
		if code != 0 {
			t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
		}
		// actionspec.Action carries no json tags → PascalCase keys ("ID").
		var actions []map[string]any
		if err := json.Unmarshal([]byte(stdout), &actions); err != nil {
			t.Fatalf("action list --json must emit a JSON array, got %q: %v", stdout, err)
		}
		if len(actions) != 1 || actions[0]["ID"] != "linux.ping" {
			t.Errorf("want one action linux.ping in the JSON, got %v", actions)
		}
		// The flag is honored: the tabwriter header row must NOT appear.
		if strings.Contains(stdout, "KIND\tRISK") || strings.Contains(stdout, "ID  PACK") {
			t.Errorf("--json must replace the table, not append to it:\n%s", stdout)
		}
	})
}

// --- RUN-013/014 — boot/config failure exits 1 ------------------------------

// A read-only command (`action list`, `action describe`) over an unresolvable
// config is a hard error: boot() fails, main prints `error: …` to stderr and
// exits 1.
func TestCLI_ReadCommandBootFailureExitsOne(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"action list, no config anywhere", []string{"action", "list"}},
		{"action list, missing --config path", []string{"--config", "/nope/missing.yaml", "action", "list"}},
		{"action describe, missing --config path", []string{"--config", "/nope/missing.yaml", "action", "describe", "linux.uptime"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, code := runCLI(t, c.args, nil)
			if code != 1 {
				t.Errorf("exit = %d, want 1; stderr=%q", code, stderr)
			}
			if !strings.Contains(stderr, "error:") {
				t.Errorf("a boot failure should print an error to stderr, got %q", stderr)
			}
			if stdout != "" {
				t.Errorf("a failed boot should produce no stdout, got %q", stdout)
			}
		})
	}
}

// --- RUN-003 — connect config-validation fatals (no live socket) -----------

// `connect` fails fast on a misconfiguration, before any dial: no cloud.url, a
// first connect with no auth key + no cached token, and a malformed signing key
// each produce a clear `error: …` on stderr and exit 1. None of these reach the
// network (the assertions return immediately, proving the fatal is hit at the
// CLI boundary, not after a dial).
func TestCLI_ConnectConfigFatals(t *testing.T) {
	base := func(t *testing.T, extra string) string {
		t.Helper()
		dir := t.TempDir()
		if err := os.MkdirAll(filepath.Join(dir, "packs"), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		cfg := "schema_version: 1\nrunner:\n  group: test\n" +
			"paths:\n  packs:\n    - " + filepath.Join(dir, "packs") + "\n  data_dir: " + filepath.Join(dir, "data") + "\n" +
			"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n" + extra
		p := filepath.Join(dir, "config.yaml")
		if err := os.WriteFile(p, []byte(cfg), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
		return p
	}

	t.Run("no cloud.url is fatal", func(t *testing.T) {
		cfg := base(t, "")
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "connect"}, nil)
		if code != 1 {
			t.Errorf("exit = %d, want 1; stderr=%q", code, stderr)
		}
		if !strings.Contains(stderr, "cloud.url not set") {
			t.Errorf("stderr should explain the missing cloud.url, got %q", stderr)
		}
		if stdout != "" {
			t.Errorf("a fatal connect produces no stdout, got %q", stdout)
		}
	})

	t.Run("first connect needs the auth key", func(t *testing.T) {
		// a loopback URL passes the transport-security gate,
		// so the failure is the missing-credential fatal, not a scheme refusal.
		cfg := base(t, "cloud:\n  url: ws://127.0.0.1:4000\n  auth_key_env: EMISAR_AUTH_KEY\n")
		// EMISAR_AUTH_KEY deliberately unset; no token file exists yet.
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "connect"}, map[string]string{"EMISAR_AUTH_KEY": ""})
		if code != 1 {
			t.Errorf("exit = %d, want 1; stderr=%q", code, stderr)
		}
		if !strings.Contains(stderr, "first connect needs $EMISAR_AUTH_KEY") || !strings.Contains(stderr, "no cached token") {
			t.Errorf("stderr should explain the missing auth key + absent token, got %q", stderr)
		}
		if stdout != "" {
			t.Errorf("a fatal connect produces no stdout, got %q", stdout)
		}
	})

	t.Run("malformed signing key is fatal", func(t *testing.T) {
		// enforce + a non-hex public key makes buildVerifier
		// fail; connect surfaces it as `signing: …` and exits 1.
		cfg := base(t, "cloud:\n  url: ws://127.0.0.1:4000\n  auth_key_env: EMISAR_AUTH_KEY\n"+
			"signing:\n  enforce_signatures: true\n  trusted_cas:\n    - ca_id: k1\n      public_key: zzzznothex\n")
		// Provide the auth key so we get PAST the credential check to buildVerifier.
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "connect"}, map[string]string{"EMISAR_AUTH_KEY": "ek-test"})
		if code != 1 {
			t.Errorf("exit = %d, want 1; stderr=%q", code, stderr)
		}
		if !strings.Contains(stderr, "signing:") || !strings.Contains(stderr, "not valid hex") {
			t.Errorf("stderr should explain the bad signing key, got %q", stderr)
		}
		if stdout != "" {
			t.Errorf("a fatal connect produces no stdout, got %q", stdout)
		}
	})
}

// --- RUN-015 — `action run` local-dispatch posture -------------------------

// `action run <id> --arg k=v --reason …` builds an engine.Request, runs the
// full local pipeline, and prints the Result JSON (exit 0). A second run with
// --stream interleaves live output before the final Result. closes
// ,.
func TestCLI_ActionRunSuccessAndStream(t *testing.T) {
	cfg := writeRunnableConfig(t, t.TempDir(), false)

	t.Run("success prints Result JSON", func(t *testing.T) {
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "why"}, nil)
		if code != 0 {
			t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
		}
		for _, want := range []string{`"status": "success"`, `"action_id": "linux.ping"`, `"executed_command": "echo hi"`} {
			if !strings.Contains(stdout, want) {
				t.Errorf("Result JSON missing %q:\n%s", want, stdout)
			}
		}
	})

	t.Run("--stream interleaves live output then Result", func(t *testing.T) {
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "why", "--stream"}, nil)
		if code != 0 {
			t.Fatalf("exit = %d, want 0; stderr=%q", code, stderr)
		}
		// The streamed stdout line ("hi") must appear BEFORE the JSON result object.
		live := strings.Index(stdout, "hi")
		result := strings.Index(stdout, `"status": "success"`)
		if live < 0 || result < 0 || live > result {
			t.Errorf("expected live output before the Result JSON; live=%d result=%d:\n%s", live, result, stdout)
		}
	})
}

// `action run` is a LOCAL bypass: validation failures and admission denials come
// back as engine *results* (the command itself exits 0 — the action failed, the
// command ran fine), and a `--arg` without `=` is the only CLI-level error
// (exit 1, parsed before the engine). ,
func TestCLI_ActionRunResultStatusesAndArgError(t *testing.T) {
	t.Run("empty reason → validation_failed result, exit 0", func(t *testing.T) {
		cfg := writeRunnableConfig(t, t.TempDir(), false)
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping"}, nil)
		if code != 0 {
			t.Fatalf("a missing reason is an engine result, not a CLI error; exit=%d stderr=%q", code, stderr)
		}
		if !strings.Contains(stdout, `"status": "validation_failed"`) || !strings.Contains(stdout, "reason required") {
			t.Errorf("expected a validation_failed result naming the missing reason:\n%s", stdout)
		}
	})

	t.Run("admission-denied → blocked_by_admission result, exit 0", func(t *testing.T) {
		cfg := writeRunnableConfig(t, t.TempDir(), true) // deny linux.ping
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "why"}, nil)
		if code != 0 {
			t.Fatalf("an admission denial is an engine result, not a CLI error; exit=%d stderr=%q", code, stderr)
		}
		if !strings.Contains(stdout, `"status": "blocked_by_admission"`) {
			t.Errorf("expected a blocked_by_admission result:\n%s", stdout)
		}
		// a local run still enforces admission — the denylist applies
		// here exactly as it would for cloud dispatch (this is not an unguarded shell).
		if !strings.Contains(stdout, "denylist") {
			t.Errorf("the denial reason should name the runner denylist:\n%s", stdout)
		}
	})

	t.Run("--arg without = is a CLI error, exit 1", func(t *testing.T) {
		cfg := writeRunnableConfig(t, t.TempDir(), false)
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "why", "--arg", "novalue"}, nil)
		if code != 1 {
			t.Errorf("a malformed --arg is a CLI error; exit=%d", code)
		}
		if !strings.Contains(stderr, "must be key=value") {
			t.Errorf("stderr should explain the --arg format, got %q", stderr)
		}
		if stdout != "" {
			t.Errorf("the parse error short-circuits before any result, stdout=%q", stdout)
		}
	})
}

// /T08 — the local-run trust boundary. With ENFORCING signing
// configured, a cloud dispatch would require a valid attestation (RUN-034); but
// `action run` is the documented local bypass — the host OS user is the trust
// boundary — so it runs WITHOUT any signature or pack-hash pin and still
// produces a success result, while a real event is journaled to the JSONL log
// (admission/validation/redaction/journal all still apply, RUN-012). closes
// ,.
func TestCLI_ActionRunLocalBypassSkipsSignatureButJournals(t *testing.T) {
	dir := t.TempDir()
	cfg := writeRunnableConfig(t, dir, false)
	// Turn on enforcing signing with a real (well-formed) trusted key. A cloud
	// dispatch would now be refused unless signed; the local path must ignore it.
	// The key below is a valid 32-byte Ed25519 public key in hex (all-zero seed's
	// public half is not constrained — any 64 hex chars that decode to 32 bytes
	// pass NewVerifier's parse), so config load + connect's buildVerifier accept it.
	validKeyHex := strings.Repeat("ab", 32)
	extra := "signing:\n  enforce_signatures: true\n  trusted_cas:\n    - ca_id: k1\n      public_key: " + validKeyHex + "\n"
	if err := appendToFile(t, cfg, extra); err != nil {
		t.Fatalf("append signing config: %v", err)
	}

	stdout, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "local-bypass"}, nil)
	if code != 0 {
		t.Fatalf("the local bypass must run despite enforcing signing; exit=%d stderr=%q", code, stderr)
	}
	// it ran (success) with no attestation — the signature gate is
	// for cloud dispatch only.
	if !strings.Contains(stdout, `"status": "success"`) {
		t.Errorf("local run under enforcing signing should still succeed:\n%s", stdout)
	}
	if strings.Contains(stdout, "signature") || strings.Contains(stdout, "refused") {
		t.Errorf("the local path must not apply the signature gate:\n%s", stdout)
	}
	// a genuine event was journaled.
	data, err := os.ReadFile(filepath.Join(dir, "events.jsonl"))
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	if !bytes.Contains(data, []byte(`"action_id":"linux.ping"`)) || !bytes.Contains(data, []byte(`"reason":"local-bypass"`)) {
		t.Errorf("a local run must journal a real event with the reason:\n%s", data)
	}
	runnerID, err := os.ReadFile(filepath.Join(dir, "data", "runner_id"))
	if err != nil {
		t.Fatalf("read durable runner id: %v", err)
	}
	wantID := `"runner_id":"` + strings.TrimSpace(string(runnerID)) + `"`
	if !bytes.Contains(data, []byte(wantID)) {
		t.Errorf("local event must carry durable runner identity %s:\n%s", wantID, data)
	}
}

// --- RUN-027 — `audit verify` chain-break exit-1 path ----------------------

// `audit verify` on a tampered/deleted chain exits 1 and names the break (file +
// line + event id) on stderr — the os.Exit(1) path (audit.go:78) that can't be
// observed in-process. An intact chain exits 0 with the chain-intact line on
// stdout, as a control.
func TestCLI_AuditVerifyChainBreakExitsOne(t *testing.T) {
	dir := t.TempDir()
	cfg := writeRunnableConfig(t, dir, false)
	jsonl := filepath.Join(dir, "events.jsonl")

	// Build a real 3-event chain by running the action three times.
	for i := 0; i < 3; i++ {
		_, stderr, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "seed"}, nil)
		if code != 0 {
			t.Fatalf("seeding the chain failed: exit=%d stderr=%q", code, stderr)
		}
	}

	// Control: the intact chain verifies clean (exit 0, chain-intact on stdout).
	stdout, _, code := runCLI(t, []string{"--config", cfg, "audit", "verify"}, nil)
	if code != 0 {
		t.Fatalf("intact chain: exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "chain intact") {
		t.Fatalf("intact chain should print the chain-intact line:\n%s", stdout)
	}

	t.Run("byte mutation in a middle line", func(t *testing.T) {
		mutate(t, jsonl, func(lines [][]byte) [][]byte {
			// Flip the recorded reason on the FIRST event; that changes its
			// serialized bytes, so the SECOND event's prev_hash no longer matches.
			lines[0] = bytes.Replace(lines[0], []byte(`"reason":"seed"`), []byte(`"reason":"XXXX"`), 1)
			return lines
		})
		stdout, stderr, code := runCLI(t, []string{"--config", cfg, "audit", "verify"}, nil)
		if code != 1 {
			t.Errorf("a tampered chain must exit 1, got %d", code)
		}
		if !strings.Contains(stderr, "chain break") || !strings.Contains(stderr, jsonl) {
			t.Errorf("stderr should name the file and the break, got %q", stderr)
		}
		if stdout != "" {
			t.Errorf("a break writes the diagnosis to stderr, not stdout; stdout=%q", stdout)
		}
	})

	t.Run("deleted line", func(t *testing.T) {
		// re-seed a clean chain first (the prior subtest
		// left the file tampered).
		if err := os.Remove(jsonl); err != nil {
			t.Fatalf("remove jsonl: %v", err)
		}
		for i := 0; i < 3; i++ {
			if _, _, code := runCLI(t, []string{"--config", cfg, "action", "run", "linux.ping", "--reason", "seed"}, nil); code != 0 {
				t.Fatalf("re-seed failed: exit=%d", code)
			}
		}
		mutate(t, jsonl, func(lines [][]byte) [][]byte {
			// Drop the middle event; the third event's prev_hash now points at a
			// line that's no longer there.
			return append(lines[:1], lines[2:]...)
		})
		_, stderr, code := runCLI(t, []string{"--config", cfg, "audit", "verify"}, nil)
		if code != 1 {
			t.Errorf("a chain with a deleted line must exit 1, got %d", code)
		}
		if !strings.Contains(stderr, "chain break") {
			t.Errorf("stderr should report a chain break, got %q", stderr)
		}
	})
}

// --- RUN-030 — version VCS lines (need a built binary, not the test binary) -

// A binary built with -buildvcs=false carries no VCS settings, so `version`
// prints only the `emisar <Version>` and `go: …` lines — no commit/built/dirty.
// A `go test` binary already omits VCS info, but building the real runner with
// the flag explicit pins the documented contract.
func TestCLI_VersionOmitsVCSWhenBuiltWithoutBuildVCS(t *testing.T) {
	bin := buildRunner(t, buildOpts{buildVCS: "false"})
	stdout := runBuilt(t, bin, "version")
	if !strings.Contains(stdout, "emisar "+Version) {
		t.Errorf("expected the version line:\n%s", stdout)
	}
	if !strings.Contains(stdout, "go: ") {
		t.Errorf("expected the go/os/arch line:\n%s", stdout)
	}
	for _, forbidden := range []string{"commit:", "built:", "vcs: dirty"} {
		if strings.Contains(stdout, forbidden) {
			t.Errorf("a -buildvcs=false build must omit %q:\n%s", forbidden, stdout)
		}
	}
}

// A binary built from a DIRTY git tree stamps `vcs.modified=true`, which
// `version` surfaces as the `vcs: dirty (uncommitted changes)` line alongside
// commit/built. We build from a throwaway git repo seeded with the runner
// sources and then dirtied, so the result is deterministic regardless of the
// developer's working-tree state.
func TestCLI_VersionShowsDirtyFlagFromDirtyTree(t *testing.T) {
	bin := buildRunner(t, buildOpts{buildVCS: "true", dirtyGitRepo: true})
	stdout := runBuilt(t, bin, "version")
	if !strings.Contains(stdout, "commit:") || !strings.Contains(stdout, "built:") {
		t.Errorf("a buildvcs=true build should carry commit/built lines:\n%s", stdout)
	}
	if !strings.Contains(stdout, "vcs: dirty (uncommitted changes)") {
		t.Errorf("a build from a dirty tree must show the dirty line:\n%s", stdout)
	}
}

// --- build helpers for the VCS rows ----------------------------------------

type buildOpts struct {
	buildVCS     string // "true" / "false" → -buildvcs=<v>
	dirtyGitRepo bool   // seed a throwaway git repo from the sources and dirty it
}

// buildRunner compiles the runner. With dirtyGitRepo, it first copies the
// package sources into a fresh git repo (committed, then a file is dirtied) so
// the build stamps vcs.modified=true deterministically. Builds are offline
// (GOPROXY=off) — every dep is already in the module cache from the suite's own
// compile — and skip the test on a toolchain/cache miss rather than fail.
func buildRunner(t *testing.T, opts buildOpts) string {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH; cannot build a binary for the VCS-line assertions")
	}
	srcDir, err := os.Getwd() // the runner package dir
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	buildDir := srcDir
	// Offline: deps are already in the module cache from the suite's own compile.
	env := append(os.Environ(), "GOPROXY=off")
	if opts.dirtyGitRepo {
		buildDir = seedDirtyGitRepo(t, srcDir)
		// The copy is a standalone module with no parent go.work — disable
		// workspace mode and resolve straight from its go.mod + the cache.
		env = append(env, "GOWORK=off", "GOFLAGS=-mod=mod")
	}
	// The in-place build at srcDir stays in the repo's workspace (go.work), so we
	// leave -mod at its workspace default; forcing -mod=mod there is an error.

	bin := filepath.Join(t.TempDir(), "emisar-built")
	args := []string{"build"}
	if opts.buildVCS != "" {
		args = append(args, "-buildvcs="+opts.buildVCS)
	}
	args = append(args, "-o", bin, ".")
	cmd := exec.Command("go", args...)
	cmd.Dir = buildDir
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("go build failed (likely an offline module-cache miss in this environment): %v\n%s", err, out)
	}
	return bin
}

// seedDirtyGitRepo copies the runner package sources into a new temp dir,
// initializes a git repo, commits, then appends a comment to a source file so
// the tree is dirty. Returns the repo dir. The copy excludes any .git so the
// new repo's HEAD is the only history the build sees.
func seedDirtyGitRepo(t *testing.T, srcDir string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH; cannot build from a dirty repo for the dirty-flag assertion")
	}
	dst := t.TempDir()
	cp := exec.Command("cp", "-R", srcDir+"/.", dst)
	if out, err := cp.CombinedOutput(); err != nil {
		t.Fatalf("copy sources: %v\n%s", err, out)
	}
	_ = os.RemoveAll(filepath.Join(dst, ".git"))

	for _, c := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "t@t.com"},
		{"config", "user.name", "t"},
		{"add", "-A"},
		{"commit", "-qm", "seed"},
	} {
		cmd := exec.Command("git", c...)
		cmd.Dir = dst
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Skipf("git %v failed seeding the dirty-repo build: %v\n%s", c, err, out)
		}
	}
	// Dirty the tree: append a harmless comment to a tracked .go file.
	if err := appendToFile(t, filepath.Join(dst, "version.go"), "\n// dirty marker for the build-vcs test\n"); err != nil {
		t.Fatalf("dirty the tree: %v", err)
	}
	return dst
}

// runBuilt runs a freshly-built runner binary with args and returns its stdout,
// failing on a non-zero exit (these helpers only run the benign `version`).
func runBuilt(t *testing.T, bin string, args ...string) string {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Env = []string{"EMISAR_CONFIG=", "HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("running built binary %v: %v\nstderr=%s", args, err, errb.String())
	}
	return out.String()
}

// appendToFile appends s to the file at path (creating nothing — the file must
// exist), used to dirty a tracked source file and to extend a config.
func appendToFile(t *testing.T, path, s string) error {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(s)
	return err
}

// mutate reads a JSONL file, splits it into lines (dropping a trailing empty
// element), applies fn, and writes the result back — used to tamper with a real
// audit chain on disk.
func mutate(t *testing.T, path string, fn func(lines [][]byte) [][]byte) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	lines := bytes.Split(bytes.TrimRight(raw, "\n"), []byte("\n"))
	lines = fn(lines)
	out := bytes.Join(lines, []byte("\n"))
	out = append(out, '\n')
	if err := os.WriteFile(path, out, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
