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
