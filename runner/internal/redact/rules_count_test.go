package redact

import "testing"

// The public site states this number in five places, each as "20 built-in":
// the security page, the docs security model, the action-packs docs page, the
// custom-MCP-server comparison, and the pricing FAQ (marketing_controller.ex),
// which the pricing page also publishes as FAQPage JSON-LD. Change them
// together with the rule set, or the pages overclaim.
func TestDefaultRulesCountMatchesThePublicPages(t *testing.T) {
	if got := len(DefaultRules()); got != 20 {
		t.Fatalf("DefaultRules() has %d rules; the public pages say 20 — update both", got)
	}
}
