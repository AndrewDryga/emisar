package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFormatCount(t *testing.T) {
	// The README spells its totals with grouped thousands, and the error message
	// offers replacement text to paste, so the grouping has to match.
	for stated, want := range map[int]string{0: "0", 4: "4", 101: "101", 1784: "1,784", 12345: "12,345", 1000000: "1,000,000"} {
		if got := formatCount(stated); got != want {
			t.Errorf("formatCount(%d) = %q, want %q", stated, got, want)
		}
	}
}

// writeCatalog builds a throwaway packs/ tree: one manifest per pack, each
// declaring the given number of actions, plus the README summary sentence.
func writeCatalog(t *testing.T, summary string, actionsPerPack ...int) string {
	t.Helper()
	root := t.TempDir()
	packs := filepath.Join(root, "packs")
	for index, count := range actionsPerPack {
		dir := filepath.Join(packs, fmt.Sprintf("pack-%d", index))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		manifest := strings.Builder{}
		manifest.WriteString("schema_version: 1\nactions:\n")
		for action := range count {
			fmt.Fprintf(&manifest, "  - actions/action-%d.yaml\n", action)
		}
		if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest.String()), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	body := "# emisar action packs\n\nThe catalog in this repository currently contains\n" + summary + " across Linux and databases.\n"
	if err := os.WriteFile(filepath.Join(packs, "README.md"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return root
}

func manifestsIn(t *testing.T, root string) []string {
	t.Helper()
	manifests, err := filepath.Glob(filepath.Join(root, "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	return manifests
}

func TestCheckPackCatalogSummary(t *testing.T) {
	t.Run("matching totals pass", func(t *testing.T) {
		root := writeCatalog(t, "**3 packs and 1,784 actions**", 1000, 784, 0)
		if err := checkPackCatalogSummary(root, manifestsIn(t, root)); err != nil {
			t.Errorf("checkPackCatalogSummary = %v, want nil", err)
		}
	})

	// The defect this check exists for: actions were removed and the prose was
	// not updated. The error has to name both numbers and the replacement text,
	// because that is the entire fix.
	t.Run("a stale action total is refused with the real count", func(t *testing.T) {
		root := writeCatalog(t, "**2 packs and 1,788 actions**", 1000, 784)
		err := checkPackCatalogSummary(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackCatalogSummary accepted a stale action total")
		}
		for _, want := range []string{"1,788", "1,784", "**2 packs and 1,784 actions**"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error does not mention %q: %v", want, err)
			}
		}
	})

	t.Run("a stale pack total is refused", func(t *testing.T) {
		root := writeCatalog(t, "**101 packs and 5 actions**", 2, 3)
		err := checkPackCatalogSummary(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackCatalogSummary accepted a stale pack total")
		}
		if !strings.Contains(err.Error(), "2 packs") {
			t.Errorf("error does not report the real pack count: %v", err)
		}
	})

	// Rewording the sentence away would otherwise disable the check silently,
	// which is a worse outcome than a wrong number.
	t.Run("a missing summary is refused", func(t *testing.T) {
		root := writeCatalog(t, "roughly a hundred packs", 2, 3)
		err := checkPackCatalogSummary(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackCatalogSummary accepted a README with no catalog summary")
		}
		if !strings.Contains(err.Error(), "exactly once") {
			t.Errorf("error does not say the summary is required: %v", err)
		}
	})

	// Two copies means the next pack change updates one of them.
	t.Run("a duplicated summary is refused", func(t *testing.T) {
		root := writeCatalog(t, "**2 packs and 5 actions** and again **2 packs and 5 actions**", 2, 3)
		err := checkPackCatalogSummary(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackCatalogSummary accepted two catalog summaries")
		}
		if !strings.Contains(err.Error(), "found 2") {
			t.Errorf("error does not report the duplicate: %v", err)
		}
	})

	// The paragraph is hand-wrapped, so the sentence can break across lines.
	t.Run("the summary may wrap across lines", func(t *testing.T) {
		root := writeCatalog(t, "**2 packs\nand 5 actions**", 2, 3)
		if err := checkPackCatalogSummary(root, manifestsIn(t, root)); err != nil {
			t.Errorf("checkPackCatalogSummary = %v, want nil for a wrapped summary", err)
		}
	})
}

// The committed README must already satisfy the check — the counts it states
// are the ones this repository ships.
func TestShippedPackCatalogSummaryIsCurrent(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	manifests := manifestsIn(t, root)
	if len(manifests) == 0 {
		t.Fatal("no pack manifests were found; the path is wrong")
	}
	if err := checkPackCatalogSummary(root, manifests); err != nil {
		t.Errorf("packs/README.md: %v", err)
	}
}
