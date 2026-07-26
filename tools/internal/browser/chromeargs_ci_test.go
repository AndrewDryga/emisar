package browser

import (
	"slices"
	"testing"
)

func TestChromeArgsDisablesSandboxUnderCI(t *testing.T) {
	t.Setenv("CI", "true")
	if !slices.Contains(chromeArgs(Config{}), "--no-sandbox") {
		t.Fatal("CI must disable the Chrome sandbox: runners have no user namespaces")
	}
	t.Setenv("CI", "")
	if slices.Contains(chromeArgs(Config{}), "--no-sandbox") {
		t.Fatal("a developer machine keeps the sandbox on")
	}
	if !slices.Contains(chromeArgs(Config{InBox: true}), "--no-sandbox") {
		t.Fatal("a coop box must disable the sandbox")
	}
}
