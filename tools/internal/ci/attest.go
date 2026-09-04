package ci

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func CheckAttestParity(root string) error {
	mcp := filepath.Join(root, "mcp", "internal", "attest")
	runner := filepath.Join(root, "runner", "internal", "attest")
	// Every non-test file in both packages, not just attest.go. Comparing one
	// named file meant a second file — mcp/internal/attest/verify.go, say — could
	// carry divergent signing or verification logic and still pass parity, which
	// is the exact thing this check exists to make impossible. Byte-identical
	// deterministic code cannot produce two different digests or signatures, so
	// each side's own tests own its fixed vectors.
	mcpFiles, err := attestSourceFiles(mcp)
	if err != nil {
		return err
	}
	runnerFiles, err := attestSourceFiles(runner)
	if err != nil {
		return err
	}
	if len(mcpFiles) == 0 {
		return fmt.Errorf("no attestation sources found under %s", mcp)
	}
	if !equalFileSets(mcpFiles, runnerFiles) {
		return fmt.Errorf("attestation implementations differ; update mcp and runner together")
	}
	return nil
}

// attestSourceFiles reads every non-test .go file in an attest package, keyed by
// base name so a file present on one side and absent on the other is a
// difference rather than something the comparison skips.
func attestSourceFiles(dir string) (map[string][]byte, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	files := make(map[string][]byte)
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		files[name] = data
	}
	return files, nil
}

func equalFileSets(left, right map[string][]byte) bool {
	if len(left) != len(right) {
		return false
	}
	for name, data := range left {
		other, ok := right[name]
		if !ok || !bytes.Equal(data, other) {
			return false
		}
	}
	return true
}
