package redact

import "testing"

// The public site states this number in four places: the security page, the
// docs security model, the action-packs docs page, and the custom-MCP-server
// comparison. Change them together with the rule set, or the pages overclaim.
func TestDefaultRulesCountMatchesThePublicPages(t *testing.T) {
	if got := len(DefaultRules()); got != 20 {
		t.Fatalf("DefaultRules() has %d rules; the public pages say 20 — update both", got)
	}
}
