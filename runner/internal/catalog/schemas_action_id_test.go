package catalog

import (
	"encoding/json"
	"os"
	"regexp"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// The published action schema is the contract a third party validates a pack
// against, so its id pattern has to accept exactly what the loader accepts. It
// used to reject every hyphenated namespace (23 shipped cloud-init actions)
// and, unanchored at the end, accept a trailing junk segment.
func TestActionSchemaIDPatternMatchesTheLoader(t *testing.T) {
	raw, err := os.ReadFile("schemas/action.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	var schema struct {
		Properties struct {
			ID struct {
				Pattern string `json:"pattern"`
			} `json:"id"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatal(err)
	}
	pattern := regexp.MustCompile(schema.Properties.ID.Pattern)
	for _, id := range []string{
		"cloud-init.analyze_dump", "rpm.dnf_upgrade", "a.b.c", "x1-y.z_2",
		"Cloud.x", "cloud", "a..b", "a.B", ".x", "a.b.", "a-.b", "a.-b",
	} {
		loader := (&actionspec.Action{SchemaVersion: actionspec.SchemaVersion, ID: id}).Validate()
		loaderAccepts := loader == nil || !isInvalidIDError(loader)
		if got := pattern.MatchString(id); got != loaderAccepts {
			t.Errorf("id %q: schema pattern accepts=%v, loader accepts=%v", id, got, loaderAccepts)
		}
	}
}

func isInvalidIDError(err error) bool {
	return regexp.MustCompile(`invalid id`).MatchString(err.Error())
}
