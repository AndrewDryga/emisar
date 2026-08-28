package main

import "testing"

// EMISAR_ALLOW_INSECURE used to require the literal "1", so setting it to
// `true` — the spelling the runner's own YAML config uses — silently left the
// HTTPS requirement ON. That is the safe direction, but the operator set the
// variable and it did nothing, with no signal either way.
func TestAllowInsecureEndpoints(t *testing.T) {
	for _, on := range []string{"1", "true", "TRUE", "True", "yes", "y", "on", " true "} {
		t.Setenv("EMISAR_ALLOW_INSECURE", on)
		if !allowInsecureEndpoints() {
			t.Errorf("%q should enable insecure endpoints", on)
		}
	}
	// Anything else keeps the safety on — including spellings that look
	// affirmative but are not, so an unrecognised value never fails open.
	for _, off := range []string{"", "0", "false", "no", "off", "maybe", "2"} {
		t.Setenv("EMISAR_ALLOW_INSECURE", off)
		if allowInsecureEndpoints() {
			t.Errorf("%q must not enable insecure endpoints", off)
		}
	}
}
