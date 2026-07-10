package packs

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// vault.token_lookup_self runs `vault token lookup -format=json`, whose JSON
// `data.id` field is the runner's OWN Vault token — often a broad/root bearer
// credential (VAULT_TOKEN). The action is risk:low (no approval gate) and its
// stdout streams to the LLM/audit, and the always-on default rules do NOT match
// a bare `"id":` key, so the token must be scrubbed at the source by the
// action's own redact rule (finding M9). This loads the REAL action from packs/
// and proves that declared rule redacts the token while leaving the surrounding
// metadata — including entity_id/request_id — intact.
func TestVaultTokenLookupSelf_RedactsTokenID(t *testing.T) {
	reg := loadRealLibrary(t)
	act, ok := reg.Action("vault.token_lookup_self")
	if !ok {
		t.Fatal("vault.token_lookup_self not found in the real library (id drifted?)")
	}

	rules := make([]redact.Rule, 0, len(act.Output.Redact))
	for _, rr := range act.Output.Redact {
		r, err := redact.CompileRule(rr)
		if err != nil {
			t.Fatalf("compiling redact rule %q: %v", rr.Name, err)
		}
		rules = append(rules, r)
	}
	if len(rules) == 0 {
		t.Fatal("vault.token_lookup_self declares NO redact rule — the token leaks")
	}

	// Representative `vault token lookup -format=json` output (a modern service
	// token in data.id — the runner's live bearer credential).
	const token = "hvs.JbYIVd4sJBzOegQDxtRDopk2"
	stdout := strings.Join([]string{
		`{`,
		`  "request_id": "8f1c0b2a-0000-0000-0000-000000000000",`,
		`  "data": {`,
		`    "accessor": "1a2b3c4d5e6f",`,
		`    "id": "` + token + `",`,
		`    "entity_id": "e0000000-0000-0000-0000-000000000000",`,
		`    "policies": ["default", "admin"],`,
		`    "ttl": 2764800`,
		`  }`,
		`}`,
	}, "\n")

	out, _ := redact.New(rules).Apply(stdout)

	if strings.Contains(out, token) {
		t.Fatalf("Vault token (data.id) leaked through redaction:\n%s", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Fatalf("expected the token to be replaced with [REDACTED], got:\n%s", out)
	}
	// The surrounding metadata the action is meant to surface must survive —
	// the leading-quote anchor must not clobber entity_id / request_id.
	if !strings.Contains(out, `"entity_id": "e0000000-0000-0000-0000-000000000000"`) {
		t.Fatalf("redaction over-matched and scrubbed entity_id:\n%s", out)
	}
	if !strings.Contains(out, `"request_id": "8f1c0b2a-0000-0000-0000-000000000000"`) {
		t.Fatalf("redaction over-matched and scrubbed request_id:\n%s", out)
	}
}
