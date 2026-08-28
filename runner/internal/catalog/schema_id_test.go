package catalog

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// A published schema object is IMMUTABLE — PUBLISHING.md promises the bytes are
// never replaced — so an `$id` naming a host that does not serve it is wrong
// forever, and the only escape is burning a SchemaArtifactVersion.
//
// v2 through v5 shipped saying `https://emisar.dev/v1/schemas/...` while the
// objects publish to the registry bucket served at `registry.emisar.dev/v1/`;
// fetching the published v5 confirms it. Those are permanent. v6 was still
// unpublished when this was found, so it was corrected in place rather than
// bumped, and this pins it so the next suite cannot inherit the same mistake.
func TestSchemaIDsNameTheHostThatServesThem(t *testing.T) {
	for name, body := range Schemas() {
		var doc struct {
			ID string `json:"$id"`
		}
		if err := json.Unmarshal(body, &doc); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want := fmt.Sprintf("https://registry.emisar.dev/v1/schemas/%s", name)
		if doc.ID != want {
			t.Errorf("%s: $id = %q, want %q", name, doc.ID, want)
		}
		// The filename carries the artifact version, so an $id that disagrees
		// with the object it names is the same defect one field over.
		if !strings.Contains(doc.ID, fmt.Sprintf(".v%d.", SchemaArtifactVersion)) {
			t.Errorf("%s: $id %q does not carry artifact version %d",
				name, doc.ID, SchemaArtifactVersion)
		}
	}
}
