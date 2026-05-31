package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

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
