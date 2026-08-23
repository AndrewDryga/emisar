package ci

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	emptyArgsPattern = regexp.MustCompile(`name:\s*"empty args"`)
	// The certificate vector is the frozen DER digest: X.509 minting from a
	// fixed template with an Ed25519 issuer is deterministic, so both
	// implementations must build byte-identical certificates.
	certDigestPattern = regexp.MustCompile(`vectorLeafDERSHA256\s*=`)
	claimSigPattern   = regexp.MustCompile(`sig:\s*` + "`")
)

func CheckAttestParity(root string) error {
	mcp := filepath.Join(root, "mcp", "internal", "attest")
	runner := filepath.Join(root, "runner", "internal", "attest")
	// Every non-test file in both packages, not just attest.go. Comparing one
	// named file meant a second file — mcp/internal/attest/verify.go, say — could
	// carry divergent signing or verification logic and still pass parity, which
	// is the exact thing this check exists to make impossible.
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
	mcpVectors, err := readAttestVectors(filepath.Join(mcp, "attest_test.go"))
	if err != nil {
		return err
	}
	runnerVectors, err := readAttestVectors(filepath.Join(runner, "attest_test.go"))
	if err != nil {
		return err
	}
	if mcpVectors != runnerVectors {
		return fmt.Errorf("attestation fixed vectors differ; update mcp and runner together")
	}
	return nil
}

func readAttestVectors(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	lines := strings.SplitAfter(string(data), "\n")
	var result strings.Builder
	inSection := false
	for _, line := range lines {
		if strings.HasPrefix(line, "const (") || strings.HasPrefix(line, "func vectorClaims()") || strings.HasPrefix(line, "func vectorChain(") || strings.HasPrefix(line, "func vectorEnvelope(") {
			inSection = true
		}
		if inSection {
			result.WriteString(line)
			// Only a column-zero delimiter closes the top-level sed-style range.
			terminator := strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
			if terminator == ")" || terminator == "}" {
				inSection = false
			}
		}
	}
	vectors := result.String()
	if !emptyArgsPattern.MatchString(vectors) || !certDigestPattern.MatchString(vectors) || !claimSigPattern.MatchString(vectors) {
		return "", fmt.Errorf("failed to extract complete attestation vectors from %s", path)
	}
	return vectors, nil
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
