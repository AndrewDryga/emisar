package ci

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCheckAttestParity(t *testing.T) {
	root := t.TempDir()
	testFile := `package attest

const (
	vectorSeedHex = "1f20"
	certBytes = "cert"
	envelopeBase64URL = "envelope"
)

func vectorClaims() int {
	if true {
		return 1
	}
	return 0
}

func vectorCert() int {
	return 2
}

func vectorEnvelope() []struct{name string} {
	return []struct{name string}{{name: "empty args"}}
}
`
	for _, module := range []string{"mcp", "runner"} {
		dir := filepath.Join(root, module, "internal", "attest")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "attest.go"), []byte("package attest\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "attest_test.go"), []byte(testFile), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := CheckAttestParity(root); err != nil {
		t.Fatal(err)
	}
	runnerTest := filepath.Join(root, "runner", "internal", "attest", "attest_test.go")
	if err := os.WriteFile(runnerTest, []byte(testFile+"\nfunc moduleSpecificFixture() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CheckAttestParity(root); err != nil {
		t.Fatalf("module-specific tests should be allowed: %v", err)
	}

	cases := []struct {
		name string
		path string
		data string
	}{
		{"implementation", "attest.go", "package attest\n// drift\n"},
		{"vector", "attest_test.go", stringReplace(testFile, "1f20", "1f21")},
		{"nested vector tail", "attest_test.go", stringReplace(testFile, "return 0", "return 2")},
		{"envelope name", "attest_test.go", stringReplace(testFile, "envelopeBase64URL", "envelopeBase64URLDrifted")},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			path := filepath.Join(root, "runner", "internal", "attest", testCase.path)
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(testCase.data), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := CheckAttestParity(root); err == nil {
				t.Fatal("one-sided drift passed parity check")
			}
			if err := os.WriteFile(path, original, 0o644); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func stringReplace(value, old, replacement string) string {
	for index := 0; index+len(old) <= len(value); index++ {
		if value[index:index+len(old)] == old {
			return value[:index] + replacement + value[index+len(old):]
		}
	}
	return value
}
