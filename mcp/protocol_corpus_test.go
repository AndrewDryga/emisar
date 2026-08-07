package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The runner carries its own hostile-JSON validator (runner/internal/jsonvalue)
// enforcing the same four rules on the same untrusted frames through completely
// different machinery: this is a hand-written byte scanner, that one is an
// encoding/json token stream. The code cannot be shared — this module stays
// stdlib-only, with no go.sum at all, which the gate asserts — so the way these
// two are kept from drifting is that both must agree on one corpus.
// runner/internal/jsonvalue/corpus_test.go reads the same file.
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

func TestSharedHostileJSONCorpus(t *testing.T) {
	path := filepath.Join("..", "dev", "json-corpus", "cases.json")
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
	// The corpus's depth cases are written against the cap this parser applies;
	// if that constant moves, the corpus has to move with it.
	if loaded.MaxDepth != maxJSONNestingDepth {
		t.Fatalf("corpus max_depth = %d, bridge caps at %d", loaded.MaxDepth, maxJSONNestingDepth)
	}

	for _, test := range loaded.Cases {
		t.Run(test.Name, func(t *testing.T) {
			raw, err := base64.StdEncoding.DecodeString(test.Base64)
			if err != nil {
				t.Fatalf("decode case input: %v", err)
			}
			err = validateStrictJSON(raw)
			if test.Valid && err != nil {
				t.Fatalf("rejected a frame the corpus accepts (%s): %v", test.Why, err)
			}
			if !test.Valid && err == nil {
				t.Fatalf("accepted a frame the corpus rejects (%s)", test.Why)
			}
		})
	}
}
