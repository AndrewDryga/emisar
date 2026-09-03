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

func TestApplyJSONMasksSecretFieldsRegardlessOfValueType(t *testing.T) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	input := []byte(`{
		"password": 42,
		"api_token": true,
		"client_secret": null,
		"private_key": {"material": "object-secret"},
		"access_key": ["array-secret"],
		"ordinary": {"nested_password": false, "count": 7}
	}`)

	output, hits, err := New(rules).ApplyJSON(input)
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(output) {
		t.Fatalf("redacted output is invalid JSON: %q", output)
	}
	var decoded map[string]any
	if err := json.Unmarshal(output, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"password", "api_token", "client_secret", "private_key", "access_key"} {
		if decoded[key] != "[REDACTED]" {
			t.Errorf("%s was not wholly redacted: %#v", key, decoded[key])
		}
	}
	ordinary, ok := decoded["ordinary"].(map[string]any)
	if !ok {
		t.Fatalf("ordinary value changed shape: %#v", decoded["ordinary"])
	}
	if ordinary["nested_password"] != "[REDACTED]" || ordinary["count"] != float64(7) {
		t.Fatalf("nested redaction changed unrelated data: %#v", ordinary)
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

// A duplicate object key must survive redaction as a defect, not be normalized
// away by it. ApplyJSON decodes into map[string]any and re-encodes, so the
// strict output-schema validator downstream would otherwise never see the
// second "name" — the document it rejects would already have been rewritten
// into one it accepts.
func TestApplyJSONRefusesDuplicateObjectKeys(t *testing.T) {
	_, _, err := Empty().ApplyJSON([]byte(`{"name":"alice","name":"bob","count":2}`))
	if !errors.Is(err, ErrInvalidJSON) {
		t.Fatalf("error=%v, want ErrInvalidJSON", err)
	}
}
