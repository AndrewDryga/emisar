package actionspec

import (
	"strings"
	"testing"
	"time"
)

// The engine compiles an action's redaction rules as one batch and keeps only
// the first rule per name, so a second rule reusing a name would never mask
// anything. Validate must refuse it instead of loading a silently weaker set.
func TestAction_Validate_RejectsDuplicateRedactionRuleNames(t *testing.T) {
	action := func(rules ...RedactionRule) *Action {
		return &Action{
			SchemaVersion: 1,
			ID:            "t.echo",
			Title:         "Echo",
			Kind:          KindExec,
			Risk:          RiskLow,
			Description:   "describes what this does",
			SideEffects:   []string{"none"},
			Execution: Execution{
				Command: &Command{Binary: "echo", Argv: []string{"hi"}},
				Timeout: Duration(5 * time.Second),
			},
			Output: Output{
				Parser:         ParserText,
				MaxStdoutBytes: 1024,
				MaxStderrBytes: 1024,
				Redact:         rules,
			},
		}
	}

	duplicate := action(
		RedactionRule{Name: "token", Type: "regex", Pattern: `tok_[a-z0-9]+`},
		RedactionRule{Name: "token", Type: "literal", Literal: "hunter2"},
	)
	err := duplicate.Validate()
	if err == nil {
		t.Fatal("duplicate redaction rule names should be rejected")
	}
	if !strings.Contains(err.Error(), `duplicate redaction rule "token"`) {
		t.Fatalf("error %q should name the duplicate rule", err)
	}

	distinct := action(
		RedactionRule{Name: "token", Type: "regex", Pattern: `tok_[a-z0-9]+`},
		RedactionRule{Name: "password", Type: "literal", Literal: "hunter2"},
	)
	if err := distinct.Validate(); err != nil {
		t.Fatalf("distinct redaction rule names should validate: %v", err)
	}
}
