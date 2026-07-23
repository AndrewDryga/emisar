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
	certBytesPattern = regexp.MustCompile(`certBytes\s*=`)
	envelopePattern  = regexp.MustCompile(`envelopeBase64URL\s*=`)
)

func CheckAttestParity(root string) error {
	mcp := filepath.Join(root, "mcp", "internal", "attest")
	runner := filepath.Join(root, "runner", "internal", "attest")
	mcpImplementation, err := os.ReadFile(filepath.Join(mcp, "attest.go"))
	if err != nil {
		return err
	}
	runnerImplementation, err := os.ReadFile(filepath.Join(runner, "attest.go"))
	if err != nil {
		return err
	}
	if !bytes.Equal(mcpImplementation, runnerImplementation) {
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
		if strings.HasPrefix(line, "const (") || strings.HasPrefix(line, "func vectorClaims()") || strings.HasPrefix(line, "func vectorCert()") || strings.HasPrefix(line, "func vectorEnvelope(") {
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
	if !emptyArgsPattern.MatchString(vectors) || !certBytesPattern.MatchString(vectors) || !envelopePattern.MatchString(vectors) {
		return "", fmt.Errorf("failed to extract complete attestation vectors from %s", path)
	}
	return vectors, nil
}
