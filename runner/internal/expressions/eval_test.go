package expressions

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func args() map[string]any {
	return map[string]any{
		"keyspace": "valorant_ks",
		"port":     int64(7199),
		"paths":    []string{"/var/log", "/tmp"},
		"flag":     true,
	}
}

func TestRender_SimpleSubstitution(t *testing.T) {
	s, err := Render("--keyspace={{ args.keyspace }} --port={{ args.port }}", args())
	if err != nil {
		t.Fatal(err)
	}
	if s != "--keyspace=valorant_ks --port=7199" {
		t.Fatalf("got %q", s)
	}
}

func TestRender_UnknownVariableFails(t *testing.T) {
	_, err := Render("{{ args.missing }}", args())
	if err == nil || !strings.Contains(err.Error(), "unknown variable") {
		t.Fatalf("expected unknown variable error, got %v", err)
	}
}

func TestRender_RejectsNonArgsRoot(t *testing.T) {
	_, err := Render("{{ steps.x.stdout }}", args())
	if err == nil {
		t.Fatal("expected error for non-args root")
	}
}

func TestRender_RejectsFunctionCalls(t *testing.T) {
	_, err := Render("{{ contains(args.keyspace, 'val') }}", args())
	if err == nil {
		t.Fatal("expected error — functions are not supported")
	}
}

func TestRenderArgv_ArrayExpansion(t *testing.T) {
	out, err := RenderArgv([]string{"-h", "{{ args.paths }}"}, args())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-h", "/var/log", "/tmp"}
	if len(out) != len(want) {
		t.Fatalf("got %v want %v", out, want)
	}
	for i := range out {
		if out[i] != want[i] {
			t.Fatalf("got %v want %v", out, want)
		}
	}
}

func TestArgStrings(t *testing.T) {
	cases := []struct {
		name string
		v    any
		want []string
	}{
		{"string scalar", "hunter2", []string{"hunter2"}},
		{"int64 scalar", int64(7199), []string{"7199"}},
		{"bool scalar", true, []string{"true"}},
		{"string slice expands per element", []string{"a", "b"}, []string{"a", "b"}},
		{"int64 slice expands per element", []int64{1, 2}, []string{"1", "2"}},
		{"any slice expands per element", []any{"a", int64(2)}, []string{"a", "2"}},
		{"empty slice", []string{}, []string{}},
		{"unformattable yields nothing", map[string]any{"k": "v"}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ArgStrings(tc.v)
			if len(got) != len(tc.want) {
				t.Fatalf("ArgStrings(%v) = %v, want %v", tc.v, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("ArgStrings(%v) = %v, want %v", tc.v, got, tc.want)
				}
			}
		})
	}
}

func TestRenderArgv_TextSubstitution(t *testing.T) {
	out, err := RenderArgv([]string{"--port={{ args.port }}"}, args())
	if err != nil {
		t.Fatal(err)
	}
	if out[0] != "--port=7199" {
		t.Fatalf("got %q", out[0])
	}
}

func TestRenderArgv_PreservesJSONNumber(t *testing.T) {
	const number = "891234567890123456.5"
	args, err := validation.Validate(
		[]actionspec.Arg{{Name: "ratio", Type: actionspec.ArgNumber, Required: true}},
		map[string]any{"ratio": json.Number(number)},
	)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	out, err := RenderArgv(
		[]string{"--ratio={{ args.ratio }}", "{{ args.ratio }}"},
		args,
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"--ratio=" + number, number}
	for i := range want {
		if out[i] != want[i] {
			t.Fatalf("argv[%d] = %q, want %q", i, out[i], want[i])
		}
	}
}

func TestRenderEnv(t *testing.T) {
	env, err := RenderEnv(map[string]string{"K": "ks={{ args.keyspace }}"}, args())
	if err != nil {
		t.Fatal(err)
	}
	if env["K"] != "ks=valorant_ks" {
		t.Fatalf("got %q", env["K"])
	}
}

func TestValidateReferences_RejectsUnknownOptionalArg(t *testing.T) {
	err := ValidateReferences(
		[]string{"{{ args.missing? }}"},
		map[string]string{"KNOWN": "{{ args.keyspace }}", "TYPO": "{{ args.missing? }}"},
		args(),
	)
	if err == nil || !strings.Contains(err.Error(), "unknown variable args.missing") {
		t.Fatalf("ValidateReferences() error = %v", err)
	}

	if _, err := RenderArgv([]string{"{{ args.missing? }}"}, args()); err != nil {
		t.Fatalf("runtime optional reference should remain optional: %v", err)
	}
}

func TestRender_BooleanFormatting(t *testing.T) {
	s, err := Render("flag={{ args.flag }}", args())
	if err != nil {
		t.Fatal(err)
	}
	if s != "flag=true" {
		t.Fatalf("got %q", s)
	}
}

func TestRender_DurationFormatting(t *testing.T) {
	in := map[string]any{"window": 5 * time.Minute}
	s, err := Render("window={{ args.window }}", in)
	if err != nil {
		t.Fatal(err)
	}
	if s != "window=5m0s" {
		t.Fatalf("got %q", s)
	}
}
