package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrunePackTestReportsKeepsTheNewest(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{
		"20260901T000000.000000000Z-1", "20260902T000000.000000000Z-1", "20260903T000000.000000000Z-1",
		"20260904T000000.000000000Z-1", "stray.txt",
	} {
		path := filepath.Join(root, name)
		if strings.HasSuffix(name, ".txt") {
			if err := os.WriteFile(path, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Join(path, "pack"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := prunePackTestReports(root, 2); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	want := []string{"20260903T000000.000000000Z-1", "20260904T000000.000000000Z-1", "stray.txt"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("kept %v, want %v", names, want)
	}
	// A missing root is not an error: the first run has nothing to prune.
	if err := prunePackTestReports(filepath.Join(root, "absent"), 2); err != nil {
		t.Fatal(err)
	}
}
