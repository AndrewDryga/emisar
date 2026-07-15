package engine

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// readJournalEvents reads every event line from the engine's JSONL log at
// <root>/events.jsonl, where setupEngine writes it.
func readJournalEvents(t *testing.T, root string) []audit.Event {
	t.Helper()
	f, err := os.Open(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var evs []audit.Event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var ev audit.Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("malformed JSONL line: %v\n%s", err, sc.Text())
		}
		evs = append(evs, ev)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return evs
}

func TestEngine_ExecutionStartPrecedesTerminalEvent(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	res, err := e.Run(context.Background(), Request{
		ControlPlaneRequestID: "req-start",
		ActionID:              "t.echo",
		Args:                  map[string]any{"msg": "hello"},
		Reason:                "verify start evidence",
	})
	if err != nil {
		t.Fatal(err)
	}
	events := readJournalEvents(t, root)
	if len(events) != 2 {
		t.Fatalf("events=%d, want execution_started plus terminal event", len(events))
	}
	if events[0].Type != audit.EventExecutionStarted || events[1].Type != audit.EventExecutionCompleted {
		t.Fatalf("event types = [%s, %s]", events[0].Type, events[1].Type)
	}
	if events[0].Caller.ControlPlaneRequestID != "req-start" {
		t.Fatalf("start request id=%q", events[0].Caller.ControlPlaneRequestID)
	}
	if events[0].Execution == nil || events[0].Execution.Binary == "" || events[0].Execution.ArgvSHA256 == "" {
		t.Fatalf("start event missing execution facts: %+v", events[0].Execution)
	}
	if events[1].Time.Before(events[0].Time) {
		t.Fatalf("terminal time %s precedes start time %s", events[1].Time, events[0].Time)
	}
	if events[1].EventID != res.EventID {
		t.Fatalf("terminal event id=%q, result id=%q", events[1].EventID, res.EventID)
	}
}

const sensitiveAuditAction = `
schema_version: 1
id: t.sensitive_audit
title: Sensitive audit
kind: exec
risk: low
description: test
side_effects: [none]
args:
  - name: password
    type: string
    required: true
    sensitive: true
execution:
  command:
    binary: echo
    argv: ["{{ args.password }}"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func TestEngine_SensitiveArgsNeverReachDurableAudit(t *testing.T) {
	e, journal, root := setupEngineExtra(t, map[string]string{
		"sensitive_audit.yaml": sensitiveAuditAction,
	})
	defer journal.Close()

	const secret = "overlap-secret-123"
	var progress strings.Builder
	result, err := e.Run(context.Background(), Request{
		ActionID: "t.sensitive_audit",
		Args:     map[string]any{"password": secret},
		Reason:   "verify audit confidentiality",
		OnProgress: func(stream executor.Stream, chunk []byte) {
			if stream == executor.StreamStdout {
				progress.Write(chunk)
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%q", result.Status, result.Reason)
	}

	body, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), secret) {
		t.Fatalf("audit journal leaked sensitive argument:\n%s", body)
	}
	if strings.Contains(result.Stdout, secret) || !strings.Contains(result.Stdout, "[REDACTED]") {
		t.Fatalf("result stdout was not redacted: %q", result.Stdout)
	}
	if progress.String() != result.Stdout {
		t.Fatalf("progress=%q, want exact redacted result stdout %q", progress.String(), result.Stdout)
	}

	wantArgv := []string{"[REDACTED]"}
	wantHash := argvSHA256("echo", wantArgv)
	events := readJournalEvents(t, root)
	if len(events) != 2 {
		t.Fatalf("events=%d, want start and terminal audit records", len(events))
	}
	for _, event := range events {
		if event.Execution == nil {
			t.Fatalf("%s has no execution audit", event.Type)
		}
		if got := strings.Join(event.Execution.Argv, "\x00"); got != wantArgv[0] {
			t.Errorf("%s argv=%q, want redacted argv", event.Type, event.Execution.Argv)
		}
		if event.Execution.ArgvSHA256 != wantHash {
			t.Errorf("%s argv hash=%q, want redacted hash %q", event.Type, event.Execution.ArgvSHA256, wantHash)
		}
		if event.Type != audit.EventExecutionStarted &&
			event.Execution.StdoutSHA256 != hashOutput(result.Stdout) {
			t.Errorf("%s stdout hash covers pre-redaction bytes", event.Type)
		}
		if event.Execution.ExecutedCommand != "echo '[REDACTED]'" {
			t.Errorf("%s command=%q", event.Type, event.Execution.ExecutedCommand)
		}
	}
}

func TestEngine_AuditStartFailurePreventsExecution(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "must-not-exist")
	action := fmt.Sprintf(`
schema_version: 1
id: t.audit_required
title: Audit required
kind: exec
risk: low
description: test
side_effects: [none]
args: []
execution:
  command:
    binary: touch
    argv: [%q]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`, marker)
	e, journal, _ := setupEngineExtra(t, map[string]string{"audit_required.yaml": action})
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.audit_required",
		Reason:   "prove fail closed",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusError || res.Reason != "local audit unavailable; action was not executed" {
		t.Fatalf("result=%+v", res)
	}
	if res.EventID != "" {
		t.Fatalf("failed audit write claimed durable event id %q", res.EventID)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("action crossed process boundary despite failed start journal: %v", err)
	}
}

func TestEngine_PreExecutionEventsNeverPersistArguments(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()
	const secret = "do-not-persist-this-value"
	req := Request{
		ControlPlaneRequestID: "req-refused",
		ActionID:              "t.echo",
		Args:                  map[string]any{"msg": secret},
		Reason:                "untrusted dispatch",
	}
	ids := []string{
		e.RecordDispatchRefusal(context.Background(), req, "signature required"),
		e.RecordDispatchCancellation(context.Background(), req, "cancelled before start"),
		e.RecordExecutionFailure(context.Background(), req, "recovered internal failure"),
	}
	for _, eventID := range ids {
		if eventID == "" {
			t.Fatal("pre-execution event missing event id")
		}
	}

	body, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), secret) {
		t.Fatal("pre-execution refusal persisted untrusted arguments")
	}
	events := readJournalEvents(t, root)
	if len(events) != 3 {
		t.Fatalf("events=%+v", events)
	}
	wantTypes := []audit.EventType{audit.EventDispatchRefused, audit.EventActionCancelled, audit.EventExecutionFailed}
	for i, ev := range events {
		if ev.Type != wantTypes[i] {
			t.Fatalf("event %d type=%q, want %q", i, ev.Type, wantTypes[i])
		}
		if ev.Request == nil || ev.Request.Reason != req.Reason {
			t.Fatalf("event %d request metadata=%+v", i, ev.Request)
		}
		if ev.Request.ArgsSHA256 != "" || len(ev.Request.ArgsRedacted) != 0 {
			t.Fatalf("event %d contains argument data: %+v", i, ev.Request)
		}
	}
}

// A dispatch the runner-local admission policy denies must be journaled as the
// dedicated EventActionBlockedByAdmission type — not a generic
// validation_failed — so a SIEM rule keyed on that string can alert on it
// (every such row is either a misconfiguration or a portal-compromise attempt).
// This drives the real engine→journal seam at engine.go:225-226: the existing
// admission tests assert the returned status and a non-empty EventID, but none
// reads the journal back to confirm the recorded event *type*; event_gap_test's
// records that type directly via j.Record without ever passing
// through Admit. This closes that seam: deny t.echo, dispatch it, then match the
// returned EventID in the journal and assert its type + the block reason.
func TestEngine_AdmissionBlockJournaledAsDedicatedEvent(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	pol, err := admission.New(nil, []string{"t.echo"}, "")
	if err != nil {
		t.Fatal(err)
	}
	e.Admission = pol

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "admission journal probe",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusBlockedByAdmission {
		t.Fatalf("status=%s reason=%q, want blocked_by_admission", res.Status, res.Reason)
	}
	if res.EventID == "" {
		t.Fatal("a blocked dispatch must still carry an event id")
	}

	// Find the journaled event that matches the returned id and assert its
	// recorded type is the dedicated admission-block type, not validation_failed.
	evs := readJournalEvents(t, root)
	var blocked *audit.Event
	for i := range evs {
		if evs[i].EventID == res.EventID {
			blocked = &evs[i]
			break
		}
	}
	if blocked == nil {
		t.Fatalf("no journal event matched the returned event id %q", res.EventID)
	}
	if blocked.Type != audit.EventActionBlockedByAdmission {
		t.Fatalf("journaled event_type=%q, want %q (a generic type would defeat a SIEM rule keyed on the admission-block string)",
			blocked.Type, audit.EventActionBlockedByAdmission)
	}
	if blocked.ActionID != "t.echo" {
		t.Fatalf("journaled action_id=%q, want t.echo", blocked.ActionID)
	}
	if !strings.Contains(blocked.Error, "denylist") {
		t.Fatalf("journaled error=%q, want the denylist reason recorded for forensics", blocked.Error)
	}
}

// (companion / positive case)
//
// The script-SHA re-verify at engine.go:306 runs on EVERY dispatch, re-reading
// the on-disk bytes and comparing to the loader-recorded hash — it is not a
// one-shot check cached after the first run. An untouched script must therefore
// keep running across repeated dispatches with checksums enabled (and each run
// records the verified script_sha256). The tamper test
// (TestEngine_ScriptTamperRefusedAtDispatch) proves the negative on a single
// mutation; this proves the positive holds dispatch after dispatch, so the
// defense-in-depth check never spuriously starts refusing an unchanged script.
func TestEngine_ScriptUnchangedRunsAcrossRedispatches(t *testing.T) {
	e, j, scriptPath := setupScriptEngine(t, packs.LoadOptions{})
	defer j.Close()

	want, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 3; i++ {
		res, err := e.Run(context.Background(), Request{ActionID: "t.run", Reason: "test"})
		if err != nil {
			t.Fatalf("dispatch %d: %v", i, err)
		}
		if res.Status != StatusSuccess {
			t.Fatalf("dispatch %d: status=%s reason=%q — an unchanged script must keep passing the re-verify",
				i, res.Status, res.Reason)
		}
		if !strings.Contains(res.Stdout, "original") {
			t.Fatalf("dispatch %d: stdout=%q, want the trusted script's output", i, res.Stdout)
		}
	}

	// The re-verify only ever reads the file; it must not have altered it.
	if got, _ := os.ReadFile(scriptPath); string(got) != string(want) {
		t.Fatal("the re-verify must read the script, never rewrite it")
	}
}

// SIGHUP pack reload is fail-safe: when re-discovery errors (a pack on disk is
// now corrupt), engine.Reload() returns the error WITHOUT swapping the registry
// (engine.go:171-182 stores the new registry only after LoadAll succeeds), so
// the runner keeps serving the last-known-good catalog rather than going dark on
// a bad edit. This drives the engine seam directly; the connect.go signal
// handler that logs "reload_failed" and skips the readvertise on this error
// lives in the main package and is out of internal-package scope, but the
// keep-old-registry guarantee it relies on is exactly this.
func TestEngine_ReloadFailureKeepsOldRegistry(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	before := e.Registry()
	if _, ok := before.Action("t.echo"); !ok {
		t.Fatal("pre-reload registry missing t.echo")
	}

	// Corrupt the pack manifest on disk so the next discovery fails to parse it.
	if err := os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte("this: is: not: valid: yaml: ["), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := e.Reload(); err == nil {
		t.Fatal("Reload must surface the discovery error on a corrupt pack, not swallow it")
	}

	// The live registry pointer must be UNCHANGED — same instance, still
	// resolving the action it had before the failed reload. A reload that
	// half-applied (swapped in an empty/partial registry) would silently strip
	// the runner's catalog on a typo.
	after := e.Registry()
	if after != before {
		t.Fatal("a failed Reload must not swap the registry pointer")
	}
	if _, ok := after.Action("t.echo"); !ok {
		t.Fatal("a failed Reload must keep the last-known-good catalog (t.echo still resolvable)")
	}
}

// twoStreamLeakAction emits one complete, independently-redactable multi-line
// secret on stdout AND a different one on stderr. The executor streams stdout
// and stderr from separate goroutines, so this exercises whether the engine
// gives each stream its own StreamRedactor (engine.go:336-337) or shares one.
const twoStreamLeakAction = `
schema_version: 1
id: t.two_stream_leak
title: Emit a multi-line secret on each of stdout and stderr
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv:
      - "-c"
      - "printf '%s\\n' out_before ==BEGINKEY== OUTLEAKBODYAAAA OUTLEAKBODYBBBB ==ENDKEY== out_after; printf '%s\\n' err_before ==BEGINKEY== ERRLEAKBODYAAAA ERRLEAKBODYBBBB ==ENDKEY== err_after 1>&2"
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 4096
  max_stderr_bytes: 4096
  redact:
    - name: pem
      type: regex
      pattern: '==BEGINKEY==[\s\S]*?==ENDKEY=='
      replacement: '[REDACTED_PEM]'
`

// The engine wires a SEPARATE StreamRedactor per stream (engine.go:336-337):
// outRed for stdout, errRed for stderr. A StreamRedactor is stateful and not
// concurrency-safe — it holds a bounded raw tail in `pending` to catch
// multi-line matches across chunk boundaries. If stdout and stderr (which
// stream from independent goroutines) shared one instance, the two streams'
// interleaved Writes would corrupt that shared buffer and a multi-line secret
// could be split across the emit boundary and leak.
//
// This asserts the soundness that per-stream instances guarantee: a complete
// multi-line secret on EACH stream is fully redacted on its own stream, in both
// the streamed chunks (which the cloud reassembles into the permanent record)
// and the captured result, while the non-secret bracketing bytes pass through.
// Two distinct secrets, each whole within one stream, can only both be masked
// if each stream owns an independent redactor.
func TestEngine_StreamingUsesSeparateRedactorPerStream(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{"two_stream_leak.yaml": twoStreamLeakAction})
	defer j.Close()

	var (
		mu        sync.Mutex
		outStream strings.Builder
		errStream strings.Builder
	)
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.two_stream_leak",
		Reason:   "per-stream redactor probe",
		OnProgress: func(stream executor.Stream, b []byte) {
			mu.Lock()
			defer mu.Unlock()
			switch stream {
			case executor.StreamStdout:
				outStream.Write(b)
			case executor.StreamStderr:
				errStream.Write(b)
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%q", res.Status, res.Reason)
	}

	mu.Lock()
	out := outStream.String()
	errOut := errStream.String()
	mu.Unlock()

	// Each (stream-label, body) the secret-body that must NOT appear in it, plus
	// the non-secret bytes that must survive on that stream.
	type check struct {
		label  string
		body   string
		secret string
		before string
		after  string
	}
	checks := []check{
		{"streamed stdout", out, "OUTLEAKBODY", "out_before", "out_after"},
		{"streamed stderr", errOut, "ERRLEAKBODY", "err_before", "err_after"},
		{"result stdout", res.Stdout, "OUTLEAKBODY", "out_before", "out_after"},
		{"result stderr", res.Stderr, "ERRLEAKBODY", "err_before", "err_after"},
	}
	for _, c := range checks {
		if strings.Contains(c.body, c.secret) {
			t.Fatalf("multi-line secret leaked in %s — a shared cross-stream redactor would split the match:\n%s",
				c.label, c.body)
		}
		if !strings.Contains(c.body, "[REDACTED_PEM]") {
			t.Fatalf("expected the redaction marker in %s, got:\n%s", c.label, c.body)
		}
		if !strings.Contains(c.body, c.before) || !strings.Contains(c.body, c.after) {
			t.Fatalf("non-secret bytes must pass through on %s: %q", c.label, c.body)
		}
	}

	// Cross-stream guard: neither stream may carry the OTHER stream's secret
	// body, which would only happen if the redactors shared buffer state.
	if strings.Contains(out, "ERRLEAKBODY") || strings.Contains(res.Stdout, "ERRLEAKBODY") {
		t.Fatal("stderr's secret bled into stdout — streams must not share a redactor")
	}
	if strings.Contains(errOut, "OUTLEAKBODY") || strings.Contains(res.Stderr, "OUTLEAKBODY") {
		t.Fatal("stdout's secret bled into stderr — streams must not share a redactor")
	}
}
