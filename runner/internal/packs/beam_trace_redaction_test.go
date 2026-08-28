package packs

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// beam.recon_trace_calls prints traced call arguments, so it ships two rules
// that mask a secret-named key's value. Elixir's inspect/1 renders any binary
// that is not printable UTF-8 as a BYTE LIST — `<<246, 15, 241, 177>>` — and
// that is the shape a real BEAM secret takes: Phoenix's secret_key_base and
// anything from :crypto.strong_rand_bytes/1 inspect exactly this way.
//
// The rules' value alternation accepted `<<"quoted">>`, a quoted string, a
// charlist, or a bare run stopping at the first comma. A byte list matched only
// the last branch, so `<<1, 2, 3, 4>>` masked to `[REDACTED], 2, 3, 4>>` — one
// byte hidden, the rest emitted, and the line LOOKS redacted to anyone scanning
// for the marker. That is worse than no rule, which is why this is pinned here
// rather than left to the pack's own gate: pack validation proves a redaction
// rule COMPILES, never that it MATCHES.
//
// The pack has no SUT (its tracer needs a live node under traffic), so this
// loads the REAL pack and drives the REAL redactor instead of a behavior case.
func TestBeamTraceRedactsInspectedByteListBinaries(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", "packs", "elixir-beam"))
	if err != nil {
		t.Fatal(err)
	}
	registry, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatalf("loading the elixir-beam pack: %v", err)
	}
	action, ok := registry.Action("beam.recon_trace_calls")
	if !ok {
		t.Fatal("beam.recon_trace_calls is missing from the loaded pack")
	}
	rules, err := redact.CompileAll(action.Output.Redact)
	if err != nil {
		t.Fatalf("compiling the action's redaction rules: %v", err)
	}
	redactor := redact.New(rules)

	// Every line is real Elixir inspect/1 output.
	masked := []struct {
		name  string
		line  string
		leaks []string
	}{
		{
			"map value as a byte list",
			`%{secret_key_base: <<1, 2, 3, 4, 5, 6, 7, 8>>}`,
			[]string{"2, 3, 4", "8>>"},
		},
		{
			"tuple value as a byte list",
			`{:password, <<246, 15, 241, 177, 86, 103, 101, 205>>}`,
			[]string{"15, 241", "205>>"},
		},
		{
			"partially printable binary",
			`%{secret: <<1, 2, "abc">>}`,
			[]string{"abc"},
		},
		{"empty binary", `%{api_key: <<>>}`, nil},
		{"quoted value still masked", `%{password: "hunter2"}`, []string{"hunter2"}},
		{"tuple quoted value still masked", `{:password, "hunter2"}`, []string{"hunter2"}},
	}
	for _, tc := range masked {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := redactor.Apply(tc.line)
			if len(hits) == 0 {
				t.Fatalf("no redaction fired on %q", tc.line)
			}
			for _, leak := range tc.leaks {
				if strings.Contains(out, leak) {
					t.Errorf("secret bytes survived redaction:\n  in:  %s\n  out: %s\n  leak: %q",
						tc.line, out, leak)
				}
			}
		})
	}

	// A traced call with no secret-named key must survive intact — the operator
	// ran the tracer to read exactly this.
	ordinary := `%{user_id: 42, name: "alice", path: "/health"}`
	if out, _ := redactor.Apply(ordinary); out != ordinary {
		t.Errorf("ordinary traced arguments were redacted:\n  in:  %s\n  out: %s", ordinary, out)
	}
}
