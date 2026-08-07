package jsonvalue

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The bridge carries its own hostile-JSON validator (strictJSONParser in
// mcp/protocol.go) enforcing the same four rules on the same untrusted frames
// through completely different machinery. The module boundary forbids sharing
// the code — mcp must stay stdlib-only, with no go.sum at all — so the runner
// and bridge attestation packages are kept honest by byte parity, and these two
// are kept honest by agreeing on one corpus. mcp/protocol_corpus_test.go reads
// the same file; a rule that stops holding on one side fails there or here.
type corpusCase struct {
	Name   string `json:"name"`
	Why    string `json:"why"`
	Valid  bool   `json:"valid"`
	Base64 string `json:"base64"`
}

type corpus struct {
	MaxDepth int          `json:"max_depth"`
	Cases    []corpusCase `json:"cases"`
}

func loadCorpus(t *testing.T) corpus {
	t.Helper()
	path := filepath.Join("..", "..", "..", "dev", "json-corpus", "cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared corpus: %v", err)
	}
	var loaded corpus
	if err := json.Unmarshal(data, &loaded); err != nil {
		t.Fatalf("parse shared corpus: %v", err)
	}
	if len(loaded.Cases) == 0 {
		t.Fatal("shared corpus is empty")
	}
	return loaded
}

func TestSharedHostileJSONCorpus(t *testing.T) {
	loaded := loadCorpus(t)
	limits := Limits{MaxDepth: loaded.MaxDepth}

	for _, test := range loaded.Cases {
		t.Run(test.Name, func(t *testing.T) {
			raw, err := base64.StdEncoding.DecodeString(test.Base64)
			if err != nil {
				t.Fatalf("decode case input: %v", err)
			}
			err = Validate(raw, limits)
			if test.Valid && err != nil {
				t.Fatalf("rejected a frame the corpus accepts (%s): %v", test.Why, err)
			}
			if !test.Valid && err == nil {
				t.Fatalf("accepted a frame the corpus rejects (%s)", test.Why)
			}
		})
	}
}
