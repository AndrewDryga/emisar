package packs

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/validation"
)

// Runtime / dispatch-time argument validation, driven against the REAL pack
// library rather than synthetic schemas.
//
// This is the exact seam the engine runs on every dispatch (engine.go:253):
//
//	act, _ := reg.Action(req.ActionID)
//	cleanArgs, err := validation.Validate(act.Args, req.Args)
//
// The runner trusts only the action ID from the cloud; it re-validates every
// supplied value against the schema it loaded LOCALLY from packs/. These tests
// prove that the constraints real authors wrote (max_length, numeric min/max,
// anchored pattern, enum, required) actually reject a hostile or malformed
// caller value at that seam — that the per-arg containment the security model
// rests on is wired end-to-end, not just exercised on hand-built Arg structs
// (the latter is internal/validation/args_test.go).
//
// Each test loads the real action and cites the pack/action + the exact
// constraint it exercises. Mirrors the runtime-validation gap rows in
// .agent/features/tests/packs.md (PCK-003 family + the PCK-1xx -T05 rows).

// dispatchValidate mirrors the engine's dispatch seam: resolve the action from
// the registry (the only cloud-trusted input is its ID) and re-validate the
// caller-supplied args against the action's locally-loaded schema. It fails the
// test if the action id has drifted out of the library.
func dispatchValidate(t *testing.T, reg *Registry, actionID string, raw map[string]any) error {
	t.Helper()
	act, ok := reg.Action(actionID)
	if !ok {
		t.Fatalf("action %q not found in the real library (id drifted?)", actionID)
	}
	_, err := validation.Validate(act.Args, raw)
	return err
}

// rejected asserts the dispatch was rejected and the failure names the expected
// arg and validation code (the structured *validation.Error the engine records
// and surfaces to the operator/LLM).
func rejected(t *testing.T, err error, wantArg, wantCode string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected dispatch to be REJECTED (arg %q, code %q), got nil error", wantArg, wantCode)
	}
	ve, ok := err.(*validation.Error)
	if !ok {
		t.Fatalf("expected *validation.Error, got %T: %v", err, err)
	}
	if ve.Arg != wantArg {
		t.Fatalf("rejection on arg %q, want %q (err: %v)", ve.Arg, wantArg, err)
	}
	if ve.Code != wantCode {
		t.Fatalf("rejection code %q, want %q (err: %v)", ve.Code, wantCode, err)
	}
}

// accepted asserts the dispatch passed validation (a valid value is not
// over-rejected — the other half of every gate).
func accepted(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("expected dispatch to be ACCEPTED, got: %v", err)
	}
}

// postgres.terminate_backend's `pid` is a
// real integer arg bounded `min: 1, max: 4194304` (the Linux pid_max ceiling).
// Drive the boundary against the actually-loaded action: 1 and 4194304 pass,
// 0 and 4194305 are rejected at dispatch. terminate_backend severs a live DB
// connection, so this bound is the only thing standing between a caller and an
// arbitrary `pg_terminate_backend(<n>)`.
func TestDispatch_PostgresTerminateBackend_PidBounds(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "postgres.terminate_backend"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": 1}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": 4194304}))

	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": 0}), "pid", "min")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": 4194305}), "pid", "max")
}

// a numeric arg outside its declared range is rejected at
// dispatch. Grounded in docker.stop's `timeout` integer arg (`min: 1, max:
// 600`): 1 and 600 accept, 0 (below min) and 601 (above max) reject. Confirms
// min/max gate on a second real action, distinct from the pid ceiling above.
func TestDispatch_DockerStop_TimeoutRange(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "docker.stop"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"container": "web", "timeout": 1}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"container": "web", "timeout": 600}))

	rejected(t, dispatchValidate(t, reg, id, map[string]any{"container": "web", "timeout": 0}), "timeout", "min")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"container": "web", "timeout": 601}), "timeout", "max")
}

// debugging.kill_pid's `pid` integer is bounded `min: 2,
// max: 4194304` (pid 1 is init — never a kill target) and a non-numeric value
// is a type error, both rejected at dispatch.
func TestDispatch_DebuggingKillPid_PidBoundsAndType(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "debugging.kill_pid"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": 2}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": 4194304}))

	// pid 1 (init) is below the declared floor of 2.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": 1}), "pid", "min")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": 4194305}), "pid", "max")
	// A non-numeric pid fails type coercion before any bound check.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": "all"}), "pid", "type")
}

// a value not in a declared enum is rejected at dispatch.
// Grounded in two real enums: debugging.kill_pid's `signal` (the kill signal
// allowlist) and linux.journalctl's `priority` (the syslog level set). A signal
// the author did not list (and an out-of-set priority) must be refused.
func TestDispatch_EnumRejectsOutOfSet(t *testing.T) {
	reg := loadRealLibrary(t)

	// kill_pid signal enum: SIGTERM/SIGINT/SIGHUP/SIGKILL/SIGUSR1/SIGUSR2/SIGQUIT.
	accepted(t, dispatchValidate(t, reg, "debugging.kill_pid", map[string]any{"pid": 100, "signal": "SIGKILL"}))
	rejected(t, dispatchValidate(t, reg, "debugging.kill_pid", map[string]any{"pid": 100, "signal": "SIGPWN"}), "signal", "enum")

	// journalctl priority enum: debug..emerg.
	accepted(t, dispatchValidate(t, reg, "linux.journalctl", map[string]any{"unit": "nginx", "priority": "err"}))
	rejected(t, dispatchValidate(t, reg, "linux.journalctl", map[string]any{"unit": "nginx", "priority": "verbose"}), "priority", "enum")
}

// `max_length` is enforced in BYTES at dispatch. Grounded
// in showcase.every_arg_type's `note` (max_length: 4096): a value at exactly
// 4096 bytes passes, 4097 is rejected, and a multibyte run is counted by BYTES
// (not runes) — 2048 two-byte runes = 4096 bytes passes, 2049 = 4098 bytes is
// rejected. Byte-counting matters because argv size (the abuse surface this
// cap bounds) is measured in bytes.
func TestDispatch_MaxLengthIsBytes(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "showcase.every_arg_type"

	at := strings.Repeat("a", 4096)
	over := strings.Repeat("a", 4097)
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "note": at}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "note": over}), "note", "max_length")

	// "é" is 2 bytes in UTF-8: 2048 of them = 4096 bytes (passes), 2049 = 4098 (fails).
	multibyteAt := strings.Repeat("é", 2048)
	if len(multibyteAt) != 4096 {
		t.Fatalf("test fixture: expected 4096 bytes, got %d", len(multibyteAt))
	}
	multibyteOver := strings.Repeat("é", 2049)
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "note": multibyteAt}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "note": multibyteOver}), "note", "max_length")
}

// closes PCK-003 (required) — a missing required arg is rejected at dispatch,
// and a valid value passes. Grounded in shell.run_script's required `script`
// (the break-glass action's sole arg). is the same row for that
// action specifically.
//
// Also `script` is bounded by max_length: 65536: a value
// at exactly 64 KiB passes, +1 byte is rejected.
func TestDispatch_ShellRunScript_RequiredAndMaxLength(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "shell.run_script"

	// Missing the required arg → rejected before anything runs.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{}), "script", "required")
	// A present value passes.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"script": "uptime"}))

	// max_length: 65536 boundary.
	at := strings.Repeat("x", 65536)
	over := strings.Repeat("x", 65537)
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"script": at}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"script": over}), "script", "max_length")
}

// nginx.status and nginx.connections_now curl a stub_status endpoint over a
// caller-supplied `url`. Both are `risk: low` (no approval gate), so an
// unconstrained host would be a gate-bypassing SSRF: a permitted low-risk MCP
// call could aim runner `curl` at cloud metadata (169.254.169.254), an RFC1918
// neighbour, or a TEST-NET target. The pattern pins the HOST to loopback
// (127.0.0.1/localhost/[::1]) and leaves only the port and path caller-varied.
// Drive both actions at the real dispatch seam: loopback URLs (with non-default
// port/path) pass; every off-host host, a `@`-userinfo loopback bypass, a
// shell-metacharacter value, and a wrong scheme are rejected by the pattern.
func TestDispatch_NginxStatus_LoopbackOnly(t *testing.T) {
	reg := loadRealLibrary(t)
	for _, id := range []string{"nginx.status", "nginx.connections_now"} {
		t.Run(id, func(t *testing.T) {
			// Loopback hosts with non-default port/path — the supported surface.
			accepted(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://127.0.0.1/nginx_status"}))
			accepted(t, dispatchValidate(t, reg, id, map[string]any{"url": "https://localhost:8443/status"}))
			accepted(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://[::1]:8080/nginx_status"}))

			// Off-host targets a low-risk read must never reach.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://169.254.169.254/latest/meta-data/"}), "url", "pattern") // cloud IMDS
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://192.168.1.1/nginx_status"}), "url", "pattern")          // RFC1918
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://10.0.0.5/nginx_status"}), "url", "pattern")             // RFC1918
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://192.0.2.1/nginx_status"}), "url", "pattern")            // TEST-NET-1
			// `@`-userinfo trick: the host is 169.254.169.254, not the loopback prefix.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://127.0.0.1@169.254.169.254/"}), "url", "pattern")
			// A space and `;` are outside the URL character class.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "http://127.0.0.1/ ; reboot"}), "url", "pattern")
			// Wrong scheme (no http/https prefix) is also refused.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"url": "file:///etc/passwd"}), "url", "pattern")
		})
	}
}

// nginx's five log-reading actions take a `log_path` interpolated into a
// `/bin/sh -c "tail ... <path>"` pipeline. The anchored pattern blocks shell
// metacharacters, but `.` and `/` are charset members so it does NOT stop `..`;
// containment against traversal (and symlink escape) rests on
// `allowed_prefixes: [/var/log/nginx]`, which runs the runner's
// Clean+EvalSymlinks check. Because all five actions are `risk: low` (no
// approval gate), a missing prefix would be a gate-bypassing arbitrary
// root-readable file read (/etc/shadow, .pgpass, arbitrary .env). Drive both
// halves at the real dispatch seam: the default log path passes, a `../` escape
// to /etc is rejected by the prefix containment, and a shell-metacharacter
// value is rejected by the pattern.
func TestDispatch_NginxLogPath_TraversalContained(t *testing.T) {
	reg := loadRealLibrary(t)
	// Every action carrying the shared log_path arg, with its declared default.
	cases := []struct {
		id      string
		defPath string
	}{
		{"nginx.error_tail", "/var/log/nginx/error.log"},
		{"nginx.access_top_clients", "/var/log/nginx/access.log"},
		{"nginx.access_top_urls", "/var/log/nginx/access.log"},
		{"nginx.log_grep_4xx", "/var/log/nginx/access.log"},
		{"nginx.log_grep_5xx", "/var/log/nginx/access.log"},
	}
	for _, c := range cases {
		t.Run(c.id, func(t *testing.T) {
			// The declared default (and a sibling rotated log) resolve under the
			// allowed prefix and pass.
			accepted(t, dispatchValidate(t, reg, c.id, map[string]any{"log_path": c.defPath}))
			accepted(t, dispatchValidate(t, reg, c.id, map[string]any{"log_path": "/var/log/nginx/access.log.1"}))

			// `../` escape to a root-readable secret: the pattern admits it (`.`
			// and `/` are charset members) but Clean collapses it to /etc/... and
			// the allowed_prefixes check rejects it.
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{
				"log_path": "/var/log/nginx/../../../etc/passwd",
			}), "log_path", "allowed_prefixes")
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{
				"log_path": "/var/log/nginx/../../../etc/shadow",
			}), "log_path", "allowed_prefixes")

			// A shell-metacharacter value is stopped earlier, by the pattern —
			// the log_path lands in a /bin/sh -c pipeline, so this is the
			// injection-containment boundary.
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{
				"log_path": "/var/log/nginx/$(id)",
			}), "log_path", "pattern")
		})
	}
}

// a path-bearing string_array is contained PER ELEMENT at dispatch, not just
// by its whole-array validators. Grounded in showcase.path_validation's
// `extras` (a string_array carrying the same allowed_prefixes /var/log,/tmp +
// denied_paths/prefixes + max_length as the scalar `file` arg): the runner runs
// applyPathValidation over every element (stringsFor), so an LLM cannot pass
// file=/var/log/syslog (allowlisted) and smuggle /etc/shadow through extras.
// This is the exact seam disk_usage.yaml's `paths` array relies on.
func TestDispatch_ShowcaseExtras_PerElementContained(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "showcase.path_validation"

	// An allowlisted file plus an allowlisted extra both pass.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{
		"file":   "/var/log/syslog",
		"extras": []any{"/tmp/run.lock"},
	}))

	// A secret path smuggled through extras — while `file` itself is a clean
	// allowlisted value — is rejected on the extras element, not silently run.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"file":   "/var/log/syslog",
		"extras": []any{"/etc/shadow"},
	}), "extras", "allowed_prefixes")

	// `../` escape inside an extras element: Clean collapses it, allowed_prefixes rejects.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"file":   "/var/log/syslog",
		"extras": []any{"/var/log/../../etc/shadow"},
	}), "extras", "allowed_prefixes")

	// The per-element deny list applies too.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"file":   "/var/log/syslog",
		"extras": []any{"/var/log/secure"},
	}), "extras", "denied_paths")

	// Each element is length-bounded (max_length: 256) — an unbounded argv is a DoS.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"file":   "/var/log/syslog",
		"extras": []any{"/var/log/" + strings.Repeat("a", 300)},
	}), "extras", "max_length")
}

// a messaging arg is bounded at dispatch. Grounded in
// kafka.delete_consumer_group's `group` (pattern `^[a-zA-Z0-9_.\-]{1,255}$`):
// a metacharacter-bearing group id is rejected; a legitimate one passes. The
// group is interpolated into a `/bin/sh -c` kafka-consumer-groups.sh pipeline,
// so the anchored pattern is the shell-containment boundary.
func TestDispatch_KafkaDeleteConsumerGroup_GroupBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "kafka.delete_consumer_group"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"group": "legacy-consumer"}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"group": "g; rm -rf /"}), "group", "pattern")
}

// a container arg is bounded at dispatch. Grounded in
// docker.stop's `container` (pattern `^[a-zA-Z0-9_.\-]{1,128}$`): a name with
// shell metacharacters / spaces is rejected, a real name/ID passes.
func TestDispatch_DockerStop_ContainerBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "docker.stop"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"container": "web-1"}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"container": "3f2a1b0c9d8e"}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"container": "web; rm -rf /"}), "container", "pattern")
}

// an orchestration node/name arg is bounded at dispatch.
// Grounded in kubernetes.cordon's `name` (pattern `^[a-z0-9][a-z0-9.\-]{0,253}$`,
// a DNS-1123-ish node name) interpolated into a `/bin/sh -c` kubectl pipeline:
// an uppercase/metacharacter value is rejected, a real node name passes.
func TestDispatch_KubernetesCordon_NodeNameBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "kubernetes.cordon"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"name": "ip-10-0-1-23.eu-west-1.compute.internal"}))
	// Leading uppercase violates the anchored class; metacharacters can't reach the shell.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"name": "Node; reboot"}), "name", "pattern")
}

// an observability query/range arg is bounded at dispatch.
// Grounded in prom.query_range's `window` (pattern `^[0-9]{1,4}[smhd]$`) and
// `step` (`^[0-9]{1,4}[sm]$`), both interpolated into a `/bin/sh -c` curl
// pipeline via env: a malformed/metacharacter window is rejected, a real one
// passes.
func TestDispatch_PromQueryRange_WindowBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "prom.query_range"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"query": "up", "window": "6h", "step": "60s"}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"query": "up", "window": "6h; id"}), "window", "pattern")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"query": "up", "step": "$(id)"}), "step", "pattern")
}

// a cloud instance-id arg is bounded at dispatch. Grounded
// in ec2.terminate_instance's `instance_id` (pattern `^i-[0-9a-f]{8,17}$`).
// terminate_instance is an irreversible critical; the tight pattern is its only
// arg containment, so a non-conforming id (wrong prefix, uppercase hex, or shell
// metacharacters) must be rejected, and a real i-... id passes.
func TestDispatch_Ec2TerminateInstance_InstanceIdBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "ec2.terminate_instance"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"instance_id": "i-0123456789abcdef0"}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"instance_id": "i-0123abcd"}))

	rejected(t, dispatchValidate(t, reg, id, map[string]any{"instance_id": "x-0123456789abcdef0"}), "instance_id", "pattern") // wrong prefix
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"instance_id": "i-0123"}), "instance_id", "pattern")              // too short (<8 hex)
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"instance_id": "i-XYZ; terminate-all"}), "instance_id", "pattern")
}

// a runtime pid arg is bounded at dispatch. Grounded in
// jvm.heap_dump (a critical that pauses the JVM and writes live heap, incl.
// secrets, to disk). Its pid arg is range-bounded; a non-numeric and an
// out-of-range value are rejected, a real pid passes. Read the real arg's
// bounds from the loaded spec so the boundary tracks the author's numbers.
func TestDispatch_JvmHeapDump_PidBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "jvm.heap_dump"
	act, ok := reg.Action(id)
	if !ok {
		t.Skipf("%s not in library", id)
	}

	// Find the pid-style integer arg + its declared min/max from the real spec.
	var pidArg string
	var min, max int64
	for _, a := range act.Args {
		if a.Type == "integer" && a.Validation != nil && a.Validation.Min != nil && a.Validation.Max != nil {
			pidArg = a.Name
			min = int64(*a.Validation.Min)
			max = int64(*a.Validation.Max)
			break
		}
	}
	if pidArg == "" {
		t.Skipf("%s declares no range-bounded integer arg to exercise", id)
	}

	// A valid pid at the declared floor passes its own bound check; a value
	// below min and a non-numeric value are rejected on that arg.
	if err := dispatchValidate(t, reg, id, map[string]any{pidArg: min - 1}); err != nil {
		if ve, ok := err.(*validation.Error); ok && ve.Arg == pidArg {
			if ve.Code != "min" {
				t.Fatalf("below-min %s: code %q, want min (err: %v)", pidArg, ve.Code, err)
			}
		}
	} else {
		t.Fatalf("%s = %d (below declared min %d) should be rejected", pidArg, min-1, min)
	}
	if err := dispatchValidate(t, reg, id, map[string]any{pidArg: max + 1}); err != nil {
		if ve, ok := err.(*validation.Error); ok && ve.Arg == pidArg && ve.Code != "max" {
			t.Fatalf("above-max %s: code %q, want max (err: %v)", pidArg, ve.Code, err)
		}
	} else {
		t.Fatalf("%s = %d (above declared max %d) should be rejected", pidArg, max+1, max)
	}
	if err := dispatchValidate(t, reg, id, map[string]any{pidArg: "lots"}); err != nil {
		if ve, ok := err.(*validation.Error); ok && ve.Arg == pidArg && ve.Code != "type" {
			t.Fatalf("non-numeric %s: code %q, want type (err: %v)", pidArg, ve.Code, err)
		}
	} else {
		t.Fatalf("non-numeric %s should be rejected on type", pidArg)
	}
}

// a datastore arg is bounded at dispatch AND the boolean
// arg passes through as a real bool (the bool-truthy-in-shell gotcha is about
// the RENDERED token; the validator's job is only to enforce the type). Grounds
// the arg-bound half in ch.kill_mutation's `database` (anchored identifier
// pattern `^[A-Za-z_][A-Za-z0-9_]{0,127}$` + max_length 128) — a SQL/metachar
// value injected into the `KILL MUTATION WHERE database='...'` clause is
// rejected. The bool half is covered separately in
// TestDispatch_BooleanArgCoercion.
func TestDispatch_ClickhouseKillMutation_IdentifierBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "ch.kill_mutation"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{
		"database": "analytics", "table": "events", "mutation_id": "mutation_3.txt",
	}))
	// A value trying to break out of the single-quoted SQL string literal.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"database": "x' OR '1'='1", "table": "events", "mutation_id": "mutation_3.txt",
	}), "database", "pattern")
}

// closes PCK-003 (coercion / bool half) — the bool, int, and string
// coercions accept the right shapes and reject the wrong ones at the real
// dispatch seam. Grounded in showcase.every_arg_type (a bool `verbose`, an
// integer `port` with an `allowed` set, a string `mode` enum):
//   - a real bool passes; a string "true" is a TYPE error (the runner does NOT
//     coerce a string into a bool — the only safe way across the shell boundary
//     is a real bool, which is exactly why pack authors prefer numeric/enum for
//     a shell-interpolated toggle);
//   - an int in the `allowed` set passes; one outside is rejected;
//   - a string in the `enum` passes; one outside is rejected.
func TestDispatch_BooleanIntStringCoercion(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "showcase.every_arg_type"

	// bool: a real bool is fine; a string is NOT silently coerced.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "verbose": true}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "verbose": "true"}), "verbose", "type")

	// int with an allowed-set: 443 is allowed, 22 is not.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "port": 443}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"mode": "fast", "port": 22}), "port", "allowed")

	// string enum: balanced is in the set, "turbo" is not.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"mode": "balanced"}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"mode": "turbo"}), "mode", "enum")
}

// closes PCK-003 (unknown-arg at the real seam) — an arg key the action does
// NOT declare is rejected at dispatch (the runner accepts only declared args;
// the cloud can't smuggle an extra slot). Grounded in bonding.status, which
// declares exactly one arg (`bond`): a valid bond passes, but adding an
// undeclared `extra` key is refused. (internal/validation/args_test.go covers
// this on a synthetic schema; this proves it on a real action.)
func TestDispatch_UnknownArgRejected_RealAction(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "bonding.status"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"bond": "bond0"}))
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"bond": "bond0", "extra": "x"}), "extra", "unknown_arg")
}

// (re-grounded at the dispatch seam) — bonding.status's
// `bond` arg is the canonical anchored pattern `^[a-zA-Z][a-zA-Z0-9._-]{0,14}$`:
// a shell-injection attempt and an over-15-char value are both rejected, a real
// bond name passes. The value is interpolated into `cat /proc/net/bonding/<bond>`,
// so the anchored class is what keeps a metacharacter out of the path.
func TestDispatch_BondingStatus_AnchoredPattern(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "bonding.status"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"bond": "bond0"}))
	// Shell metacharacters.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"bond": "bond0; reboot"}), "bond", "pattern")
	// 16 chars — one past the {0,14} tail (1 + 15).
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"bond": "abcdefghijklmnop"}), "bond", "pattern")
}

// a metric-label arg is LENGTH-bounded at dispatch, not just charset-anchored.
// Grounded in vm.label_values's `label` (pattern `^[a-zA-Z_][a-zA-Z0-9_]{0,127}$`):
// the value is rendered into the URL path `/api/v1/label/<label>/values`, so the
// anchored class already blocks metacharacters, but before the fix the `*`
// quantifier left length unbounded — a ~8 MiB all-`a` label passed validation
// and was transmitted to VictoriaMetrics (a bounded request-amplification DoS).
// The `{0,127}` tail is what now rejects an over-128-char value at this seam;
// a real short label name passes.
func TestDispatch_VmLabelValues_LabelLengthBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "vm.label_values"

	accepted(t, dispatchValidate(t, reg, id, map[string]any{"label": "job"}))
	// 128 chars total (1 lead + 127 tail) is the ceiling and still accepted.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"label": "a" + strings.Repeat("b", 127)}))
	// 129 chars — one past the {0,127} tail — is rejected on length by the pattern.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"label": "a" + strings.Repeat("b", 128)}), "label", "pattern")
}

// nomad.job_dispatch's `meta_kv` is a caller-supplied string interpolated into a
// `/bin/sh -c` loop that builds an unbounded `-meta k=v -meta k=v ...` argv for
// `nomad job dispatch`. Its anchored pattern bounds each pair, but the trailing
// `(,...)*` left the PAIR COUNT unbounded — so a multi-megabyte `a=b,a=b,...`
// (every pair individually valid) passed validation and reached the shell,
// either failing with E2BIG or dispatching a job bloated with tens of thousands
// of meta vars (a bounded resource/DoS abuse). `max_length: 1024` is what now
// caps total argv size at the dispatch seam; a realistic meta string passes.
func TestDispatch_NomadJobDispatch_MetaKvLengthBounded(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "nomad.job_dispatch"

	// A realistic meta value (the action's own shipped example) passes.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"job": "batch-processor", "meta_kv": "input=/tmp/data,priority=high"}))
	// 1024 bytes total is the ceiling and still accepted: "a=b" + ",a=b"*255 = 3 + 1020 = 1023 bytes,
	// pad one more valid char to hit exactly 1024.
	at := "ab=b" + strings.Repeat(",a=b", 255)
	if len(at) != 1024 {
		t.Fatalf("test fixture: expected 1024 bytes, got %d", len(at))
	}
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"job": "batch-processor", "meta_kv": at}))

	// A pair-flood that matches the pattern but exceeds 1024 bytes is rejected on
	// length before it can build an oversized argv.
	over := "a=b" + strings.Repeat(",a=b", 400) // 1603 bytes, every pair valid
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"job": "batch-processor", "meta_kv": over}), "meta_kv", "max_length")
}

// nomad.job_dispatch's `job` and nomad.alloc_restart's `alloc_id`/`task` are
// interpolated as BARE positionals into `nomad job dispatch … <job>` /
// `nomad alloc restart -task <task> <alloc_id>` — no `--` end-of-flags guard.
// Their identifier patterns anchor the first character to a non-dash class
// (`^[a-zA-Z0-9]…` / `^[a-fA-F0-9]…`) so a value like `-verbose` / `-help` can
// never reach argv as a leading-dash token nomad would read as a CLI flag
// (fail-safe misparse, and inconsistent with the sibling script actions that
// use `nomad job inspect -- "$job"`). Drive the real dispatch seam: legit ids
// pass; a leading-dash value is rejected on the pattern.
func TestDispatch_NomadExecMutators_NoLeadingDashIdentifier(t *testing.T) {
	reg := loadRealLibrary(t)

	// job_dispatch.job — legit id passes, a flag-looking value is rejected.
	accepted(t, dispatchValidate(t, reg, "nomad.job_dispatch", map[string]any{"job": "batch-processor"}))
	rejected(t, dispatchValidate(t, reg, "nomad.job_dispatch", map[string]any{"job": "-verbose"}), "job", "pattern")

	// alloc_restart.alloc_id — a real hex alloc id passes; a leading-dash value
	// (and the empty task, which stays optional) exercise both args.
	accepted(t, dispatchValidate(t, reg, "nomad.alloc_restart", map[string]any{"alloc_id": "abc12345"}))
	accepted(t, dispatchValidate(t, reg, "nomad.alloc_restart", map[string]any{"alloc_id": "abc12345", "task": "web"}))
	rejected(t, dispatchValidate(t, reg, "nomad.alloc_restart", map[string]any{"alloc_id": "-0badf00d"}), "alloc_id", "pattern")
	rejected(t, dispatchValidate(t, reg, "nomad.alloc_restart", map[string]any{"alloc_id": "abc12345", "task": "-help"}), "task", "pattern")
}

// cockroach.set_cluster_setting's `value` is interpolated verbatim into a
// `/bin/sh -c "cockroach sql ... -e \"SET CLUSTER SETTING <name> = <value>\""`
// pipeline — landing inside the double-quoted `-e` slot where `$(...)`, a
// backtick, and a `"`-breakout `;` all execute. The quoted alternative of the
// pattern is the only shell-containment boundary (the runner does NOT escape),
// so it must exclude `"` `$` backtick `\`. Drive the real dispatch seam: the
// shipped legit values ('64 MiB', DEFAULT) pass, and command-substitution /
// quote-breakout payloads that the pre-fix `'[^']…'` alternative admitted are
// now rejected on the pattern.
func TestDispatch_CockroachSetClusterSetting_ValueShellSafe(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "cockroach.set_cluster_setting"
	const name = "kv.snapshot_rebalance.max_rate"

	// Real setting values — a quoted byte size and the bare DEFAULT token.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"name": name, "value": "'64 MiB'"}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"name": name, "value": "DEFAULT"}))

	// Command substitution and a `"`-breakout `;`-chain — both matched the old
	// `'[^']{1,254}'` alternative; the shell-safe charset now rejects them.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"name": name, "value": "'$(touch /tmp/pwned)'"}), "value", "pattern")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"name": name, "value": `'" ; id ; "'`}), "value", "pattern")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"name": name, "value": "'`id`'"}), "value", "pattern")
}

// iam.detach_user_policy's `policy_arn` gates the ARN passed to `aws iam
// detach-user-policy`. The action's whole purpose ("remove overly broad
// permissions during an incident") — and its own shipped example — is detaching
// an AWS-MANAGED policy like arn:aws:iam::aws:policy/AdministratorAccess, whose
// account segment is the literal token `aws`, not a 12-digit customer id. The
// old `:iam::[0-9]{12}:policy/` pattern rejected exactly that value, breaking
// the advertised capability at the dispatch seam. Drive the real seam: the
// managed ARN and a customer-account ARN both pass; shell-metacharacter and
// wrong-service ARNs are still rejected on the pattern.
func TestDispatch_IamDetachUserPolicy_ArnAcceptsManaged(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "iam.detach_user_policy"

	// AWS-managed policy (account segment is the literal `aws`) — the action's
	// own example and its reason to exist. This is the value the old pattern
	// wrongly rejected.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess",
	}))
	// A 12-digit customer-account ARN still passes.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws:iam::123456789012:policy/team/DevAccess",
	}))
	// A non-default partition (GovCloud) still passes — the bounded partition
	// segment `[a-zA-Z\-]{0,14}` covers aws-cn / aws-us-gov / aws-iso*.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws-us-gov:iam::aws:policy/AdministratorAccess",
	}))

	// A metacharacter-bearing account segment can't reach argv, and a wrong
	// service (`s3`) is not an IAM policy ARN.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws:iam::aws;reboot:policy/x",
	}), "policy_arn", "pattern")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws:s3:::aws:policy/x",
	}), "policy_arn", "pattern")
	// The partition segment was the sole unbounded quantifier (`[a-zA-Z\-]*`);
	// bounding it to {0,14} rejects an oversized partition instead of matching
	// an arbitrarily long value.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{
		"user_name": "intern", "policy_arn": "arn:aws" + strings.Repeat("a", 5034) + ":iam::aws:policy/x",
	}), "policy_arn", "pattern")
}

// rmq.close_connection's `pid` gates the connection PID passed to `rabbitmqctl
// close_connection`. Real RabbitMQ PIDs from `list_connections pid` carry the
// node name — `<rabbit@host.1.123.0>` (the form in RabbitMQ's own docs, this
// action's shipped example, and the pack test case). The old `^<[0-9.]+>$`
// pattern allowed only bare-numeric `<0.123.0>` and rejected every real
// node-prefixed PID, breaking the high-risk action at the dispatch seam. Drive
// the real seam: the node-prefixed and bare-numeric forms both pass; a
// shell-metacharacter value is still rejected on the pattern.
func TestDispatch_RmqCloseConnection_PidAcceptsNodePrefix(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "rmq.close_connection"

	// The node-prefixed PID — the action's own example and the value the old
	// pattern wrongly rejected — plus the bare-numeric form.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": "<rabbit@host.1.123.0>"}))
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"pid": "<0.123.0>"}))

	// Shell metacharacters and a missing bracket can't reach argv.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": "<rabbit@host; reboot>"}), "pid", "pattern")
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"pid": "0.123.0"}), "pid", "pattern")
}

// dnf-rpm's package/pkg args are interpolated as BARE positionals into
// `dnf remove -y <package>` / `dnf upgrade -y <pkg>` / `rpm -qi <package>` — no
// `--` end-of-flags guard. The old `^[a-zA-Z0-9_.+\-]{1,128}$` pattern admitted a
// leading `-`, so a value like `--duplicates` / `--security` reached dnf as a
// flag: `dnf remove -y --duplicates` removes a whole CLASS of packages and
// `dnf upgrade -y --security` upgrades everything security-flagged, defeating the
// pack's "single named package, others untouched" intent (three of these are
// high-risk, approval-gated — this is scope-broadening WITHIN a gated action).
// The fix anchors the first char to `^[a-zA-Z0-9]…` (mirroring reinstall_pkg), so
// a flag-looking value can never reach argv. Drive the real dispatch seam: real
// package names pass; the flag-injection values are rejected on the pattern.
func TestDispatch_DnfRpmPackage_NoLeadingDashFlag(t *testing.T) {
	reg := loadRealLibrary(t)

	// (action id, arg name) for every mutator/read that carries the package arg.
	cases := []struct {
		id, arg string
	}{
		{"rpm.dnf_remove", "package"},
		{"dnf.upgrade_pkg", "pkg"},
		{"rpm.dnf_install", "package"},
		{"rpm.rpm_qi", "package"},
		{"rpm.rpm_ql", "package"},
	}
	for _, c := range cases {
		t.Run(c.id, func(t *testing.T) {
			// Real package names — plain, versioned, and dotted — all pass.
			accepted(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "nginx"}))
			accepted(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "kernel-core"}))
			accepted(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "python3.11"}))

			// A leading-dash value the old loose pattern admitted — the concrete
			// dnf/rpm flag-injection payloads — is now rejected on the pattern.
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "--duplicates"}), c.arg, "pattern")
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "--security"}), c.arg, "pattern")
			rejected(t, dispatchValidate(t, reg, c.id, map[string]any{c.arg: "-y"}), c.arg, "pattern")
		})
	}
}
