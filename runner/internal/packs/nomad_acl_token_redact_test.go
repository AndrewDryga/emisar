package packs

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// nomad.acl_token_self runs `nomad acl token self`, which prints the caller's
// own token INCLUDING its `Secret ID = <uuid>` — the runner's NOMAD_TOKEN
// bearer credential. The action is risk:low (no approval gate) and its stdout
// streams to the LLM/audit, so the Secret ID must be scrubbed at the source by
// the action's own redact rule (finding B3). This loads the REAL action from
// packs/ and proves that declared rule actually redacts the credential while
// leaving the surrounding metadata intact — the sibling consul.acl_token_self
// carries the equivalent rule.
func TestNomadAclTokenSelf_RedactsSecretID(t *testing.T) {
	reg := loadRealLibrary(t)
	act, ok := reg.Action("nomad.acl_token_self")
	if !ok {
		t.Fatal("nomad.acl_token_self not found in the real library (id drifted?)")
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
		t.Fatal("nomad.acl_token_self declares NO redact rule — the Secret ID leaks")
	}

	// Representative `nomad acl token self` output (a management token, the
	// worst case: whole-cluster control). Column-aligned like the real CLI.
	const secret = "9d3cac19-1111-2222-3333-444455556666"
	stdout := strings.Join([]string{
		"Accessor ID  = 1a2b3c4d-0000-0000-0000-000000000000",
		"Secret ID    = " + secret,
		"Name         = Bootstrap Token",
		"Type         = management",
		"Global       = true",
		"Policies     = n/a",
		"Create Time  = 2026-07-09 00:00:00 +0000 UTC",
	}, "\n")

	out, _ := redact.New(rules).Apply(stdout)

	if strings.Contains(out, secret) {
		t.Fatalf("Secret ID leaked through redaction:\n%s", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Fatalf("expected the Secret ID to be replaced with [REDACTED], got:\n%s", out)
	}
	// The surrounding metadata the action is meant to surface must survive.
	if !strings.Contains(out, "Type         = management") {
		t.Fatalf("redaction over-matched and scrubbed non-secret metadata:\n%s", out)
	}
}
