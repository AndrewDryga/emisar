package redact

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestApplyJSONPreservesEscapingWhileRedactingValuesAndSecretFields(t *testing.T) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	engine := New(rules)
	input := []byte(`{"message":"quote\" slash\\ pwd=x","token":"ordinary-\"value","ok":true}`)

	output, hits, err := engine.ApplyJSON(input)
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(output) {
		t.Fatalf("redacted output is invalid JSON: %q", output)
	}
	if strings.Contains(string(output), "pwd=x") || strings.Contains(string(output), "ordinary-") {
		t.Fatalf("secret survived redaction: %s", output)
	}
	var decoded map[string]any
	if err := json.Unmarshal(output, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["message"] != `quote" slash\ pwd=[REDACTED]` {
		t.Fatalf("message escaping was not preserved: %#v", decoded["message"])
	}
	if decoded["token"] != "[REDACTED]" {
		t.Fatalf("secret-named field was not redacted: %#v", decoded["token"])
	}
	if len(hits) == 0 {
		t.Fatal("redactions were not reported")
	}
}

func TestApplyJSONFailsClosedWhenWholeDocumentRuleBreaksJSON(t *testing.T) {
	rule, err := CompileRule(actionspec.RedactionRule{
		Name: "bad-document-rule", Type: "regex", Pattern: `"ok":true`, Replacement: `"ok`,
	})
	if err != nil {
		t.Fatal(err)
	}
	output, hits, err := New([]Rule{rule}).ApplyJSON([]byte(`{"ok":true}`))
	if !errors.Is(err, ErrUnsafeJSONRedaction) {
		t.Fatalf("error=%v, want ErrUnsafeJSONRedaction", err)
	}
	if string(output) != "null" || !json.Valid(output) {
		t.Fatalf("unsafe replacement escaped as %q", output)
	}
	if len(hits) != 1 || hits[0].Name != "bad-document-rule" {
		t.Fatalf("hits=%+v", hits)
	}
}
