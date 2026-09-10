package engine

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/expressions"
	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// The portal's Emisar.Catalog.CommandPreview is a hand port of this module's
// rendering: the operator approves the line it renders, and this module
// renders the line that runs. Both read dev/command-corpus/cases.json; the
// portal's command_preview_corpus_test.exs is the other half. A case is the
// dispatch pipeline end to end — validate (defaults, coercion), render, mask,
// quote — because that is what the operator's approval has to match.
type commandCorpusCase struct {
	Name   string           `json:"name"`
	Why    string           `json:"why"`
	Binary string           `json:"binary"`
	Argv   []string         `json:"argv"`
	Specs  []actionspec.Arg `json:"specs"`
	Args   string           `json:"args"`
	Want   string           `json:"want"`
}

func loadCommandCorpus(t *testing.T) []commandCorpusCase {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "dev", "command-corpus", "cases.json"))
	if err != nil {
		t.Fatalf("read shared corpus: %v", err)
	}
	var loaded struct {
		Cases []commandCorpusCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &loaded); err != nil {
		t.Fatalf("parse shared corpus: %v", err)
	}
	if len(loaded.Cases) == 0 {
		t.Fatal("shared corpus holds no cases")
	}
	return loaded.Cases
}

func TestRenderedCommandMatchesSharedCorpus(t *testing.T) {
	for _, tc := range loadCommandCorpus(t) {
		t.Run(tc.Name, func(t *testing.T) {
			// Decode the arguments the way the cloud client decodes a dispatch:
			// numbers stay exact tokens, never float64.
			decoder := json.NewDecoder(bytes.NewReader([]byte(tc.Args)))
			decoder.UseNumber()
			var raw map[string]any
			if err := decoder.Decode(&raw); err != nil {
				t.Fatalf("decode args: %v", err)
			}
			clean, err := validation.Validate(tc.Specs, raw, nil)
			if err != nil {
				t.Fatalf("validate: %v", err)
			}
			rendered, err := expressions.RenderArgv(tc.Argv, clean)
			if err != nil {
				t.Fatalf("render: %v", err)
			}
			_, got := redactedInvocation(nil, tc.Binary, rendered, clean, tc.Specs)
			if got != tc.Want {
				t.Fatalf("%s\n got: %s\nwant: %s", tc.Why, got, tc.Want)
			}
		})
	}
}
