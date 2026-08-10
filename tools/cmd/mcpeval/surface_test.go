package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/tools/internal/repo"
)

// Every published tool must be classified as read-only or mutation. An
// unclassified one is invisible until a client calls it mid-certification and
// gets tool_not_allowed — which reads as the client misbehaving and costs a
// full qualification run to discover. That happened twice; this makes the third
// time a unit-test failure instead.
func TestEveryPublishedToolIsClassified(t *testing.T) {
	root, err := repo.Root()
	if err != nil {
		t.Skipf("outside a checkout: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(root,
		"portal", "apps", "emisar_web", "priv", "mcp", "api-schemas.json"))
	if err != nil {
		t.Skipf("schema unavailable: %v", err)
	}
	var schema struct {
		Tools map[string]json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatal(err)
	}
	if len(schema.Tools) == 0 {
		t.Fatal("no tools in the published schema")
	}
	readOnly := stringSet(readOnlyTools)
	for tool := range schema.Tools {
		if !readOnly[tool] && !mutationTools[tool] {
			t.Errorf("published tool %q is neither read-only nor a mutation: a scenario "+
				"would block it as tool_not_allowed", tool)
		}
	}
	for tool := range readOnly {
		if _, published := schema.Tools[tool]; !published {
			t.Errorf("read-only allowlist names %q, which the portal does not publish", tool)
		}
	}
}
