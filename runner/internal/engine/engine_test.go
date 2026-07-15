package engine

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

const echoAction = `
schema_version: 1
id: t.echo
title: Echo
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: msg
    type: string
    required: true
execution:
  command:
    binary: /bin/echo
    argv:
      - "{{ args.msg }}"
  timeout: 5s
  timeout_min: 1s
  timeout_max: 10s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

const cancellableAction = `
schema_version: 1
id: t.cancellable
title: Cancellable
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "sleep 30"]
  timeout: 5s
  timeout_min: 100ms
  timeout_max: 5s
  cancel_grace: 100ms
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func setupEngine(t *testing.T) (*Engine, *audit.Journal, string) {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(`schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoAction), 0o644))
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	must(err)
	sink, err := audit.OpenJSONL(filepath.Join(root, "events.jsonl"), audit.JSONLOptions{})
	must(err)
	j := audit.New(audit.Defaults{AgentID: "test", Group: "test"}, sink)
	e := New(Config{
		Registry:     reg,
		Executor:     executor.New(),
		Journal:      j,
		Redactor:     redact.Empty(),
		PreviewBytes: 256,
		PackDirs:     []string{root},
	})
	return e, j, root
}

func TestEngine_Success(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
	}
	if !strings.Contains(res.Stdout, "hi") {
		t.Fatalf("stdout=%q", res.Stdout)
	}
	if res.EventID == "" {
		t.Fatal("expected event id")
	}
}

func TestEngine_PreservesCancellationAndTimeoutStatuses(t *testing.T) {
	e, j, root := setupEngineExtra(t, map[string]string{"cancellable.yaml": cancellableAction})
	defer j.Close()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()
	cancelled, err := e.Run(ctx, Request{ActionID: "t.cancellable", Reason: "cancel probe"})
	if err != nil {
		t.Fatal(err)
	}
	if cancelled.Status != StatusCancelled || cancelled.Reason != "execution cancelled" {
		t.Fatalf("cancelled result = status %s reason %q", cancelled.Status, cancelled.Reason)
	}

	timedOut, err := e.Run(context.Background(), Request{
		ActionID: "t.cancellable",
		Reason:   "timeout probe",
		Opts:     Opts{Timeout: 100 * time.Millisecond},
	})
	if err != nil {
		t.Fatal(err)
	}
	if timedOut.Status != StatusTimedOut || timedOut.Reason != "execution timed out" {
		t.Fatalf("timed-out result = status %s reason %q", timedOut.Status, timedOut.Reason)
	}

	journal, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	for _, eventType := range []string{`"event_type":"action_cancelled"`, `"event_type":"execution_failed"`} {
		if !strings.Contains(string(journal), eventType) {
			t.Fatalf("journal missing %s:\n%s", eventType, journal)
		}
	}
}

func TestEngine_ValidationFailed(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{}, // missing msg
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusValidationFailed {
		t.Fatalf("status=%s", res.Status)
	}
}

func TestEngine_UnknownAction(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	res, err := e.Run(context.Background(), Request{ActionID: "nope.nada", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusUnknownAction {
		t.Fatalf("status=%s", res.Status)
	}
}

func TestEngine_AdmissionDenylistBlocks(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	pol, err := admission.New(nil, []string{"t.echo"}, "")
	if err != nil {
		t.Fatal(err)
	}
	e.Admission = pol

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusBlockedByAdmission {
		t.Fatalf("expected blocked, got status=%s reason=%s", res.Status, res.Reason)
	}
	if !strings.Contains(res.Reason, "denylist") {
		t.Fatalf("expected denylist reason, got %q", res.Reason)
	}
	if res.EventID == "" {
		t.Fatal("expected an event id on the blocked result")
	}
}

func TestEngine_AdmissionAllowlistGate(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	// Allowlist that doesn't include t.echo.
	pol, err := admission.New([]string{"linux.*"}, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	e.Admission = pol

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusBlockedByAdmission {
		t.Fatalf("expected blocked, got status=%s", res.Status)
	}
	if !strings.Contains(res.Reason, "allowlist") {
		t.Fatalf("expected allowlist reason, got %q", res.Reason)
	}
}

func TestEngine_AdmissionPassesThrough(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	// Allowlist that DOES include t.echo.
	pol, err := admission.New([]string{"t.*"}, []string{"t.dangerous"}, "")
	if err != nil {
		t.Fatal(err)
	}
	e.Admission = pol

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("expected success, got status=%s reason=%s", res.Status, res.Reason)
	}
}

func TestEngine_OptsTimeoutClamped(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	// Action declares timeout_min=1s, timeout_max=10s. A 30m override should
	// be clamped to 10s.
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "x"},
		Opts:     Opts{Timeout: 30 * time.Minute},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s", res.Status)
	}
	// We can't directly observe the clamped timeout from the result, but
	// the JSONL event records it. The fact that the action succeeded
	// (and didn't hang) is the practical check.
}

func TestEngine_Reload_SwapsRegistry(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	if _, ok := e.Registry().Action("t.echo"); !ok {
		t.Fatal("initial state missing t.echo")
	}

	// Add a new action file on disk and reload.
	newAction := strings.Replace(echoAction, "id: t.echo", "id: t.shout", 1)
	if err := os.WriteFile(filepath.Join(root, "p", "actions", "shout.yaml"), []byte(newAction), 0o644); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "p", "pack.yaml")
	manifest, _ := os.ReadFile(manifestPath)
	updated := strings.Replace(string(manifest), "actions:\n  - actions/echo.yaml\n",
		"actions:\n  - actions/echo.yaml\n  - actions/shout.yaml\n", 1)
	if err := os.WriteFile(manifestPath, []byte(updated), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := e.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.Registry().Action("t.shout"); !ok {
		t.Fatal("reload should have added t.shout")
	}
	if _, ok := e.Registry().Action("t.echo"); !ok {
		t.Fatal("reload should have kept t.echo")
	}
}

// An in-flight run keeps the registry pointer it captured at start across a
// SIGHUP atomic swap. The engine holds the registry behind an atomic.Pointer
// (engine.go) and a run reads it once at startup; Reload() stores a brand-new
// registry without mutating the old one, so a dispatch that already captured
// the old pointer continues against the catalog it began with — the new packs
// only affect runs that start after the reload. This is what makes SIGHUP
// non-disruptive to actions already running.
func TestEngine_Reload_InFlightKeepsCapturedRegistry(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	// What an in-flight run does at startup: capture the live registry once.
	captured := e.Registry()
	if _, ok := captured.Action("t.echo"); !ok {
		t.Fatal("captured registry missing t.echo")
	}

	// Operator installs a new action and SIGHUPs (Reload swaps the pointer).
	newAction := strings.Replace(echoAction, "id: t.echo", "id: t.shout", 1)
	if err := os.WriteFile(filepath.Join(root, "p", "actions", "shout.yaml"), []byte(newAction), 0o644); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "p", "pack.yaml")
	manifest, _ := os.ReadFile(manifestPath)
	updated := strings.Replace(string(manifest), "actions:\n  - actions/echo.yaml\n",
		"actions:\n  - actions/echo.yaml\n  - actions/shout.yaml\n", 1)
	if err := os.WriteFile(manifestPath, []byte(updated), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := e.Reload(); err != nil {
		t.Fatal(err)
	}

	// The atomic swap installed a DIFFERENT registry instance for new runs...
	if e.Registry() == captured {
		t.Fatal("Reload must swap in a new registry pointer, not mutate the old one")
	}
	// ...and that fresh registry sees the new action.
	if _, ok := e.Registry().Action("t.shout"); !ok {
		t.Fatal("post-reload registry should resolve the newly added t.shout")
	}
	// But the pointer the in-flight run captured is unchanged: it still
	// resolves its original action and is NOT retroactively given the new one.
	if _, ok := captured.Action("t.echo"); !ok {
		t.Fatal("captured registry must still resolve the action the run started with")
	}
	if _, ok := captured.Action("t.shout"); ok {
		t.Fatal("captured registry must not see packs added after the run started — the swap is copy-on-write, not in-place")
	}
}

func TestEngine_RunUsesVerifiedRegistrySnapshot(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	verified := e.Registry()
	newAction := strings.Replace(echoAction, "id: t.echo", "id: t.shout", 1)
	if err := os.WriteFile(filepath.Join(root, "p", "actions", "shout.yaml"), []byte(newAction), 0o644); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "p", "pack.yaml")
	manifest, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	updated := strings.Replace(string(manifest), "actions:\n  - actions/echo.yaml\n",
		"actions:\n  - actions/echo.yaml\n  - actions/shout.yaml\n", 1)
	if err := os.WriteFile(manifestPath, []byte(updated), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := e.Reload(); err != nil {
		t.Fatal(err)
	}

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.shout", Args: map[string]any{"msg": "hello"}, Reason: "test",
		RegistrySnapshot: verified,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Status != StatusUnknownAction {
		t.Fatalf("status = %s, want unknown_action from the verified pre-reload registry", res.Status)
	}
	if _, ok := e.Registry().Action("t.shout"); !ok {
		t.Fatal("test did not install a different current registry")
	}
}

// jsonOkAction emits valid JSON. parserRequiredAction emits non-JSON
// and asks the engine to fail when parsing fails.
const jsonOkAction = `
schema_version: 1
id: t.json_ok
title: JSON ok
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/echo
    argv: ['{"name":"alice","ok":true}']
  timeout: 5s
output:
  parser: json
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

const jsonRequiredAction = `
schema_version: 1
id: t.json_required
title: JSON required
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/echo
    argv: ["not actually json"]
  timeout: 5s
output:
  parser: json
  parser_required: true
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func setupEngineExtra(t *testing.T, extras map[string]string) (*Engine, *audit.Journal, string) {
	t.Helper()
	e, j, root := setupEngine(t)
	// Drop additional action YAMLs in.
	for name, body := range extras {
		if err := os.WriteFile(filepath.Join(root, "p", "actions", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Re-write the manifest to include them.
	mp := filepath.Join(root, "p", "pack.yaml")
	old, _ := os.ReadFile(mp)
	new := string(old)
	for name := range extras {
		new = strings.Replace(new, "actions:\n  - actions/echo.yaml\n",
			"actions:\n  - actions/echo.yaml\n  - actions/"+name+"\n", 1)
	}
	if err := os.WriteFile(mp, []byte(new), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := e.Reload(); err != nil {
		t.Fatal(err)
	}
	return e, j, root
}

func TestEngine_JSONParserHappyPath(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{
		"json_ok.yaml": jsonOkAction,
	})
	defer j.Close()
	res, err := e.Run(context.Background(), Request{ActionID: "t.json_ok", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
	}
	if res.ParserError != "" {
		t.Fatalf("parser_error should be empty: %s", res.ParserError)
	}
	m, ok := res.Output.(map[string]any)
	if !ok {
		t.Fatalf("expected map output, got %T", res.Output)
	}
	if m["name"] != "alice" {
		t.Fatalf("parsed output wrong: %+v", m)
	}
}

func TestEngine_JSONParserError_NotRequired(t *testing.T) {
	// json parser fails to parse, but parser_required is false → status
	// stays success, parser_error is populated.
	const yaml = `
schema_version: 1
id: t.json_soft
title: JSON soft
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/echo
    argv: ["not actually json"]
  timeout: 5s
output:
  parser: json
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
	e, j, _ := setupEngineExtra(t, map[string]string{"json_soft.yaml": yaml})
	defer j.Close()
	res, err := e.Run(context.Background(), Request{ActionID: "t.json_soft", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s (parser_required=false should keep status success)", res.Status)
	}
	if res.ParserError == "" {
		t.Fatal("parser_error should be set when stdout isn't valid JSON")
	}
}

// Regression for a silent bug: when the caller requested streaming
// (cloud-side dispatch ALWAYS does), the engine used to leave the
// captured stdout empty after the run, then run `parser: json` on the
// empty string. Empty isn't valid JSON, so every `parser_required: true`
// action falsely reported `status: failed` even though the process
// exited cleanly with valid JSON on its stream.
func TestEngine_JSONParser_StreamingPath(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{
		"json_ok.yaml": jsonOkAction,
	})
	defer j.Close()

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.json_ok",
		Reason:   "test",
		// Setting OnProgress flips the engine into streaming mode.
		OnProgress: func(_ executor.Stream, _ []byte) {},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s — streaming should not break the json parser. err=%q reason=%q",
			res.Status, res.ParserError, res.Reason)
	}
	if res.ParserError != "" {
		t.Fatalf("parser_error should be empty under streaming: %q", res.ParserError)
	}
	if _, ok := res.Output.(map[string]any); !ok {
		t.Fatalf("expected parsed map output, got %T (%v)", res.Output, res.Output)
	}
	if res.Stdout == "" {
		t.Fatal("stdout should be captured under streaming, not silently dropped")
	}
}

func TestEngine_JSONParserError_RequiredFlipsStatus(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{
		"json_required.yaml": jsonRequiredAction,
	})
	defer j.Close()
	res, err := e.Run(context.Background(), Request{ActionID: "t.json_required", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusFailed {
		t.Fatalf("status=%s (parser_required: true must flip to failed)", res.Status)
	}
	if res.ParserError == "" {
		t.Fatal("parser_error should still be set")
	}
}

func TestEngine_StreamingProgress(t *testing.T) {
	e, j, _ := setupEngine(t)
	defer j.Close()
	var (
		mu     sync.Mutex
		chunks []string
	)
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "stream"},
		Reason:   "test",
		OnProgress: func(_ executor.Stream, line []byte) {
			mu.Lock()
			defer mu.Unlock()
			chunks = append(chunks, string(line))
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s", res.Status)
	}
	// Streaming runs MUST still capture redacted stdout in res — the
	// post-run consumers (json parser, audit journal entry, MCP wait=
	// result body) all rely on it. Old behavior of "leave it empty"
	// silently broke `parser: json` on every cloud-dispatched call.
	if !strings.Contains(res.Stdout, "stream") {
		t.Fatalf("streaming runs must still capture stdout for the parser/audit; got %q", res.Stdout)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(chunks) == 0 || !strings.Contains(strings.Join(chunks, ""), "stream") {
		t.Fatalf("expected streamed chunks containing 'stream', got %v", chunks)
	}
}

// leakAction emits a multi-line secret bracketed by sentinels the action's own
// redaction rule matches across lines. Because the executor ships output one
// line at a time, a per-chunk redactor would never see the whole block and
// would stream the body out unredacted.
const leakAction = `
schema_version: 1
id: t.leak
title: Emit a multi-line secret
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
      - "printf '%s\\n' before ==BEGINKEY== AAAALEAKYKEYBODYAAAA BBBBLEAKYKEYBODYBBBB ==ENDKEY== after"
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 4096
  max_stderr_bytes: 1024
  redact:
    - name: pem
      type: regex
      pattern: '==BEGINKEY==[\s\S]*?==ENDKEY=='
      replacement: '[REDACTED_PEM]'
`

// TestEngine_StreamingRedactsMultiLineSecret is the engine-level guard for the
// streaming redaction bypass: a secret whose redaction rule spans lines must be
// masked in BOTH the streamed chunks (which the cloud reassembles into the
// permanent run record) and the captured result/journal stdout.
func TestEngine_StreamingRedactsMultiLineSecret(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{"leak.yaml": leakAction})
	defer j.Close()

	var (
		mu       sync.Mutex
		streamed strings.Builder
	)
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.leak",
		Reason:   "test",
		OnProgress: func(_ executor.Stream, b []byte) {
			mu.Lock()
			defer mu.Unlock()
			streamed.Write(b)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
	}

	mu.Lock()
	stream := streamed.String()
	mu.Unlock()

	for label, body := range map[string]string{"streamed chunks": stream, "result stdout": res.Stdout} {
		if strings.Contains(body, "LEAKYKEYBODY") {
			t.Fatalf("multi-line secret leaked in %s:\n%s", label, body)
		}
		if !strings.Contains(body, "[REDACTED_PEM]") {
			t.Fatalf("expected redaction marker in %s, got:\n%s", label, body)
		}
		// Non-secret bytes on either side must survive untouched.
		if !strings.Contains(body, "before") || !strings.Contains(body, "after") {
			t.Fatalf("non-secret output should pass through in %s: %q", label, body)
		}
	}
}

const truncatedPrivateKeyAction = `
schema_version: 1
id: t.truncated_private_key
title: Emit a private key beyond the output limit
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
      - |
        printf 'before\n-----BEGIN RSA PRIVATE KEY-----\n'
        i=0
        while [ "$i" -lt 200 ]; do
          printf 'TRUNCATEDKEYBODY0123456789\n'
          i=$((i + 1))
        done
        printf '%s\n' '-----END RSA PRIVATE KEY-----'
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 512
  max_stderr_bytes: 1024
`

// The executor truncates raw output before the engine flushes its streaming
// redactor. A complete BEGIN marker followed by a body but no delivered END
// marker must remain masked in both progress and the durable result.
func TestEngine_StreamingRedactsPrivateKeyTruncatedBeforeEnd(t *testing.T) {
	e, j, root := setupEngineExtra(t, map[string]string{"truncated_private_key.yaml": truncatedPrivateKeyAction})
	defer j.Close()
	rules, err := redact.CompileAll(redact.DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	e.Redactor = redact.New(rules)

	var (
		mu       sync.Mutex
		streamed strings.Builder
	)
	res, err := e.Run(context.Background(), Request{
		ActionID: "t.truncated_private_key",
		Reason:   "truncation redaction probe",
		OnProgress: func(_ executor.Stream, b []byte) {
			mu.Lock()
			defer mu.Unlock()
			streamed.Write(b)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%q", res.Status, res.Reason)
	}
	mu.Lock()
	stream := streamed.String()
	mu.Unlock()

	for label, body := range map[string]string{"streamed chunks": stream, "result stdout": res.Stdout} {
		if strings.Contains(body, "TRUNCATEDKEYBODY") {
			t.Fatalf("truncated private key leaked in %s: %q", label, body)
		}
		if body != "before\n[REDACTED_PRIVATE_KEY]" {
			t.Fatalf("unexpected %s: %q", label, body)
		}
	}
	if !res.TruncatedOut {
		t.Fatal("stdout truncation was not propagated to the durable result")
	}
	if res.StdoutBytes != len(res.Stdout) {
		t.Fatalf("cloud stdout bytes=%d, emitted redacted bytes=%d", res.StdoutBytes, len(res.Stdout))
	}
	wantHash := sha256.Sum256([]byte(res.Stdout))
	if res.StdoutSHA256 != fmt.Sprintf("%x", wantHash) {
		t.Fatalf("cloud stdout hash=%q, want digest of emitted redacted output %x", res.StdoutSHA256, wantHash)
	}

	body, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var ev audit.Event
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(body))), &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Execution.StdoutBytes <= 512 {
		t.Fatalf("local raw stdout bytes=%d, want proof that executor truncation metadata remains local", ev.Execution.StdoutBytes)
	}
}

const scriptRunAction = `
schema_version: 1
id: t.run
title: Run a script
kind: script
risk: low
description: d
side_effects: [none]
args: []
execution:
  script:
    path: scripts/run.sh
    interpreter: /bin/sh
  argv: []
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

// setupScriptEngine builds an engine serving a single script-kind action whose
// payload lives at <root>/p/scripts/run.sh, and returns the engine and that
// script's absolute path so a test can tamper with it on disk. opts controls
// whether the loader records the script checksum.
func setupScriptEngine(t *testing.T, opts packs.LoadOptions) (*Engine, *audit.Journal, string) {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.MkdirAll(filepath.Join(root, "p", "scripts"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(`schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/run.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "run.yaml"), []byte(scriptRunAction), 0o644))
	scriptPath := filepath.Join(root, "p", "scripts", "run.sh")
	must(os.WriteFile(scriptPath, []byte("#!/bin/sh\necho original\n"), 0o755))

	reg, err := packs.LoadAll([]string{root}, opts)
	must(err)
	sink, err := audit.OpenJSONL(filepath.Join(root, "events.jsonl"), audit.JSONLOptions{})
	must(err)
	j := audit.New(audit.Defaults{AgentID: "test", Group: "test"}, sink)
	e := New(Config{
		Registry:     reg,
		Executor:     executor.New(),
		Journal:      j,
		Redactor:     redact.Empty(),
		PreviewBytes: 256,
		PackDirs:     []string{root},
	})
	return e, j, scriptPath
}

// TestEngine_ScriptTamperRefusedAtDispatch — a script whose bytes change on
// disk after the pack was loaded/trusted must be refused at the next dispatch,
// not executed. Guards the load-to-exec TOCTOU on script payloads.
func TestEngine_ScriptTamperRefusedAtDispatch(t *testing.T) {
	e, j, scriptPath := setupScriptEngine(t, packs.LoadOptions{})
	defer j.Close()

	// First dispatch runs the trusted bytes.
	res, err := e.Run(context.Background(), Request{ActionID: "t.run", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("trusted script should run: status=%s reason=%s", res.Status, res.Reason)
	}
	if !strings.Contains(res.Stdout, "original") {
		t.Fatalf("unexpected stdout: %q", res.Stdout)
	}

	// Swap the script on disk WITHOUT reloading — the registry keeps the
	// trusted hash, mirroring an attacker editing the file post-trust.
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho TAMPERED\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	res, err = e.Run(context.Background(), Request{ActionID: "t.run", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusError {
		t.Fatalf("tampered script must be refused, got status=%s stdout=%q", res.Status, res.Stdout)
	}
	if !strings.Contains(res.Reason, "changed on disk") {
		t.Fatalf("expected a tamper reason, got %q", res.Reason)
	}
	if strings.Contains(res.Stdout, "TAMPERED") {
		t.Fatal("tampered script must not have executed")
	}
}

// TestEngine_ScriptChecksumSkipRunsAnyBytes — with checksums disabled at load
// (an explicit operator opt-out), there is no recorded hash to verify against,
// so a post-load edit runs. Confirms the opt-out path and that the verifier
// no-ops on an empty recorded hash rather than failing closed and breaking
// script execution entirely.
func TestEngine_ScriptChecksumSkipRunsAnyBytes(t *testing.T) {
	e, j, scriptPath := setupScriptEngine(t, packs.LoadOptions{SkipScriptChecksum: true})
	defer j.Close()

	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho EDITED\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := e.Run(context.Background(), Request{ActionID: "t.run", Reason: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("with checksums disabled the script should run: status=%s reason=%s", res.Status, res.Reason)
	}
	if !strings.Contains(res.Stdout, "EDITED") {
		t.Fatalf("expected the edited script to run, got %q", res.Stdout)
	}
}
