package main

import "testing"

// The flag / env / default precedence was copy-pasted at four call sites, and
// EMISAR_PACKS_REGISTRY is on the frozen environment inventory — so a fifth
// pack verb that forgot the env-var line would silently ignore an operator's
// private registry, which is not visible by reading the verb.
func TestResolveRegistry(t *testing.T) {
	t.Run("the flag wins", func(t *testing.T) {
		t.Setenv("EMISAR_PACKS_REGISTRY", "https://env.example")
		if got := resolveRegistry("https://flag.example"); got != "https://flag.example" {
			t.Errorf("resolveRegistry = %q, want the flag", got)
		}
	})

	t.Run("the env var is next", func(t *testing.T) {
		t.Setenv("EMISAR_PACKS_REGISTRY", "https://env.example")
		if got := resolveRegistry(""); got != "https://env.example" {
			t.Errorf("resolveRegistry = %q, want the env value", got)
		}
	})

	t.Run("the default is last", func(t *testing.T) {
		t.Setenv("EMISAR_PACKS_REGISTRY", "")
		if got := resolveRegistry(""); got != defaultRegistry {
			t.Errorf("resolveRegistry = %q, want %q", got, defaultRegistry)
		}
	})
}
