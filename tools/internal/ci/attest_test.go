package ci

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCheckAttestParity(t *testing.T) {
	root := t.TempDir()
	implementation := "package attest\n\nfunc Verify() bool { return true }\n"
	for _, module := range []string{"mcp", "runner"} {
		dir := filepath.Join(root, module, "internal", "attest")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "attest.go"), []byte(implementation), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := CheckAttestParity(root); err != nil {
		t.Fatal(err)
	}

	// Only the implementations have to match: each module keeps its own tests,
	// which are what pin its fixed vectors.
	runnerTest := filepath.Join(root, "runner", "internal", "attest", "attest_test.go")
	if err := os.WriteFile(runnerTest, []byte("package attest\n\nfunc moduleSpecificFixture() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CheckAttestParity(root); err != nil {
		t.Fatalf("module-specific tests should be allowed: %v", err)
	}

	// A file on one side only is drift, not something the comparison skips.
	runnerExtra := filepath.Join(root, "runner", "internal", "attest", "verify.go")
	if err := os.WriteFile(runnerExtra, []byte("package attest\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CheckAttestParity(root); err == nil {
		t.Fatal("an extra runner source passed parity check")
	}
	if err := os.Remove(runnerExtra); err != nil {
		t.Fatal(err)
	}

	runnerImplementation := filepath.Join(root, "runner", "internal", "attest", "attest.go")
	if err := os.WriteFile(runnerImplementation, []byte(implementation+"// drift\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CheckAttestParity(root); err == nil {
		t.Fatal("one-sided implementation drift passed parity check")
	}
}
