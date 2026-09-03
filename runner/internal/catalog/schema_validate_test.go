package catalog

import (
	"encoding/json"
	"strings"
	"testing"
)

// minimalCatalog is the smallest document the published schema accepts. Tests
// mutate a copy of it, so each case states exactly one defect.
func minimalCatalog(t *testing.T) map[string]any {
	t.Helper()
	const doc = `{
	  "schema_version": 1,
	  "generation": 1,
	  "packs": [{
	    "id": "redis",
	    "name": "Redis operations",
	    "version": "0.3.0",
	    "description": "Redis reads and bounded maintenance.",
	    "vendor": "emisar",
	    "homepage": "https://emisar.dev/packs/redis",
	    "source_url": "https://github.com/andrewdryga/emisar/tree/main/packs/redis",
	    "content_hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
	    "tarball_url": "https://registry.emisar.dev/v1/packs/redis/0.3.0/pack.tar.gz",
	    "requires": {"os": [], "binaries": []},
	    "detect": {"binaries": [], "processes": [], "ports": []},
	    "actions": []
	  }]
	}`
	var m map[string]any
	if err := json.Unmarshal([]byte(doc), &m); err != nil {
		t.Fatalf("fixture is not valid JSON: %v", err)
	}
	return m
}

func encode(t *testing.T, doc any) []byte {
	t.Helper()
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("encoding fixture: %v", err)
	}
	return data
}

func TestValidateCatalogDocument_AcceptsAMinimalCatalog(t *testing.T) {
	if err := ValidateCatalogDocument(encode(t, minimalCatalog(t))); err != nil {
		t.Fatalf("minimal catalog should validate: %v", err)
	}
}

func TestValidateCatalogDocument_RejectsCatalogWithoutGeneration(t *testing.T) {
	doc := minimalCatalog(t)
	delete(doc, "generation")
	if err := ValidateCatalogDocument(encode(t, doc)); err == nil {
		t.Fatal("published v7 catalog without a generation should be rejected")
	}
}

func TestValidateCatalogDocument_RejectsInvalidGeneration(t *testing.T) {
	for _, generation := range []any{0, -1, "1", float64(MaxGeneration) + 1} {
		doc := minimalCatalog(t)
		doc["generation"] = generation
		if err := ValidateCatalogDocument(encode(t, doc)); err == nil {
			t.Errorf("generation %#v should be rejected", generation)
		}
	}
}

func TestValidateCatalogDocument_AcceptsMaximumGeneration(t *testing.T) {
	doc := minimalCatalog(t)
	doc["generation"] = MaxGeneration
	if err := ValidateCatalogDocument(encode(t, doc)); err != nil {
		t.Fatalf("maximum generation should validate: %v", err)
	}
}

// The shapes CD's old jq predicate (`schema_version == 1 and packs non-empty`)
// waved through. Each one silently amputates history when carried forward as
// `--previous`: carryForward hands a missing pack an empty history, and
// checkDrift permits versions to disappear.
func TestValidateCatalogDocument_RejectsWhatTheShallowPredicateAccepted(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(map[string]any)
		wantErr string
	}{
		{
			name:    "no packs at all",
			mutate:  func(m map[string]any) { m["packs"] = []any{} },
			wantErr: "packs",
		},
		{
			name: "a pack with no content hash",
			mutate: func(m map[string]any) {
				delete(m["packs"].([]any)[0].(map[string]any), "content_hash")
			},
			wantErr: "content_hash",
		},
		{
			name: "a pack with no version",
			mutate: func(m map[string]any) {
				delete(m["packs"].([]any)[0].(map[string]any), "version")
			},
			wantErr: "version",
		},
		{
			name:    "an unknown top-level key",
			mutate:  func(m map[string]any) { m["totally_unexpected"] = true },
			wantErr: "totally_unexpected",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := minimalCatalog(t)
			tc.mutate(doc)

			err := ValidateCatalogDocument(encode(t, doc))
			if err == nil {
				t.Fatal("expected the schema to reject this document")
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error should name %q, got: %v", tc.wantErr, err)
			}
		})
	}
}

// A retained snapshot is frozen at publication, so it can never gain a field
// added later — 154 entries in the live catalog carry a null `search_terms`
// for exactly that reason. Validating history as strictly as a current
// descriptor would reject our own published catalog.
func TestValidateCatalogDocument_AcceptsFrozenHistoryMissingLaterFields(t *testing.T) {
	doc := minimalCatalog(t)
	pack := doc["packs"].([]any)[0].(map[string]any)
	pack["previous_versions"] = []any{map[string]any{
		"version":      "0.2.0",
		"content_hash": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
		"tarball_url":  "https://registry.emisar.dev/v1/packs/redis/0.2.0/pack.tar.gz",
		"actions": []any{map[string]any{
			"id":           "redis.info",
			"search_terms": nil,
			"summary":      "",
			"side_effects": nil,
		}},
	}}

	if err := ValidateCatalogDocument(encode(t, doc)); err != nil {
		t.Fatalf("frozen history should validate: %v", err)
	}
}

// A history entry still has to identify the bytes it names.
func TestValidateCatalogDocument_RejectsHistoryWithoutItsContentHash(t *testing.T) {
	doc := minimalCatalog(t)
	pack := doc["packs"].([]any)[0].(map[string]any)
	pack["previous_versions"] = []any{map[string]any{
		"version":     "0.2.0",
		"tarball_url": "https://registry.emisar.dev/v1/packs/redis/0.2.0/pack.tar.gz",
	}}

	err := ValidateCatalogDocument(encode(t, doc))
	if err == nil {
		t.Fatal("a history entry without content_hash should be rejected")
	}
	if !strings.Contains(err.Error(), "content_hash") {
		t.Fatalf("error should name content_hash, got: %v", err)
	}
}

func TestValidateCatalogDocument_RejectsNonJSON(t *testing.T) {
	if err := ValidateCatalogDocument([]byte("not json")); err == nil {
		t.Fatal("expected a parse error")
	}
}
