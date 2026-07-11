package expressions

import (
	"strings"
	"testing"
	"time"
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

func TestRenderEnv(t *testing.T) {
	env, err := RenderEnv(map[string]string{"K": "ks={{ args.keyspace }}"}, args())
	if err != nil {
		t.Fatal(err)
	}
	if env["K"] != "ks=valorant_ks" {
		t.Fatalf("got %q", env["K"])
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
