package selfupdate

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// One historical release per artifact is grandfathered: it predates the trusted
// reusable release workflow, so it is verified against its original signer
// workflow plus an explicit signer digest instead. That exemption is a
// SIGNATURE-VERIFICATION relaxation, and it is currently spelled out in nine
// places across Go, bash and PowerShell — where install-mcp.sh and
// install-mcp.ps1 express the SAME exemption and can never fail each other, so
// updating the bash pin leaves the PowerShell installer silently on the old
// policy with its own fixture still green.
//
// This test is the one place that decides they agree. Each artifact has exactly
// one owner and every other site is compared against it, never restated here:
//
//   - runner: the constants in selfupdate.go (production code owns it)
//   - mcp:    install-mcp.sh (no Go production code carries the bridge's pin)
//
// Retiring an exemption is equally a deliberate edit here: a release that drops
// the block fails this test until the expectation is dropped with it.
func TestAttestationGrandfatherPinIsOnePolicy(t *testing.T) {
	root := repoRoot(t)

	runnerPin := attestationPin{
		tag:      legacyRunnerTag,
		workflow: legacySignerWorkflow,
		digest:   legacySignerDigest,
	}
	if got := shellPin(t, root, "install.sh"); got != runnerPin {
		t.Errorf("install.sh pins %+v; selfupdate.go's constants say %+v", got, runnerPin)
	}
	// The in-package fixture the security suite verifies against.
	if testLegacyIdentity.workflow != runnerPin.workflow || testLegacyIdentity.digest != runnerPin.digest {
		t.Errorf("testLegacyIdentity %+v does not match the constants %+v", testLegacyIdentity, runnerPin)
	}

	mcpPin := shellPin(t, root, "install-mcp.sh")
	if got := powershellPin(t, root, "install-mcp.ps1"); got != mcpPin {
		t.Errorf("install-mcp.ps1 pins %+v; install-mcp.sh pins %+v — the two installers must express one exemption", got, mcpPin)
	}

	// The installer behavior harness restates each triple in its expected
	// traces. A fixture that still asserts a retired pin is a green test
	// proving the wrong policy.
	for path, want := range map[string]attestationPin{
		"tools/internal/installtest/runner.go":      runnerPin,
		"tools/internal/installtest/mcp.go":         mcpPin,
		"tools/internal/installtest/mcp_windows.go": mcpPin,
	} {
		body := readRepoFile(t, root, path)
		for label, value := range map[string]string{"tag": want.tag, "workflow": want.workflow, "digest": want.digest} {
			if !strings.Contains(body, value) {
				t.Errorf("%s does not carry the %s %q it must assert", path, label, value)
			}
		}
	}
}

// attestationPin is one grandfathered release: the tag it applies to, the
// pre-split workflow that signed it, and the signer digest pinned with it.
type attestationPin struct {
	tag      string
	workflow string
	digest   string
}

var (
	shellPinTag      = regexp.MustCompile(`if \[ "\$\{VERSION\}" = "([^"]+)" \]; then`)
	shellPinWorkflow = regexp.MustCompile(`ATTESTATION_WORKFLOW="([^"]*)"`)
	shellPinDigest   = regexp.MustCompile(`ATTESTATION_SIGNER_DIGEST="([^"]*)"`)

	powershellPinTag      = regexp.MustCompile(`if \(\$Tag -ceq "([^"]+)"\) \{`)
	powershellPinWorkflow = regexp.MustCompile(`\$workflow = "([^"]*)"`)
	powershellPinDigest   = regexp.MustCompile(`\$signerDigest = "([^"]*)"`)
)

func shellPin(t *testing.T, root, path string) attestationPin {
	t.Helper()
	return parsePin(t, path, readRepoFile(t, root, path), pinGrammar{
		tag: shellPinTag, workflow: shellPinWorkflow, digest: shellPinDigest, blockEnd: "\n  fi\n",
	})
}

func powershellPin(t *testing.T, root, path string) attestationPin {
	t.Helper()
	return parsePin(t, path, readRepoFile(t, root, path), pinGrammar{
		tag: powershellPinTag, workflow: powershellPinWorkflow, digest: powershellPinDigest, blockEnd: "\n    }\n",
	})
}

type pinGrammar struct {
	tag      *regexp.Regexp
	workflow *regexp.Regexp
	digest   *regexp.Regexp
	blockEnd string
}

// parsePin reads the exemption out of an installer. The tag test opens the
// block and is unique in each installer; the workflow and digest assignments
// are not, so they are read from inside that block rather than from the file —
// both installers also assign the DEFAULT trusted workflow and an empty digest.
func parsePin(t *testing.T, path, body string, g pinGrammar) attestationPin {
	t.Helper()
	opens := g.tag.FindAllStringSubmatchIndex(body, -1)
	if len(opens) != 1 {
		t.Fatalf("%s: found %d grandfather blocks, want exactly 1 — a retired or added exemption must be reflected in this test", path, len(opens))
	}
	block := body[opens[0][0]:]
	if end := strings.Index(block, g.blockEnd); end >= 0 {
		block = block[:end]
	}
	pin := attestationPin{tag: body[opens[0][2]:opens[0][3]]}
	pin.workflow = onlyCapture(t, path, "workflow", block, g.workflow)
	pin.digest = onlyCapture(t, path, "signer digest", block, g.digest)
	return pin
}

func onlyCapture(t *testing.T, path, label, block string, re *regexp.Regexp) string {
	t.Helper()
	found := re.FindAllStringSubmatch(block, -1)
	if len(found) != 1 {
		t.Fatalf("%s: found %d %s assignments in the grandfather block, want exactly 1:\n%s", path, len(found), label, block)
	}
	return found[0][1]
}

func readRepoFile(t *testing.T, root, path string) string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(body)
}

// repoRoot walks up from the package directory to the checkout that carries the
// public installers. The pin lives in files three modules apart, so the one
// test that reconciles them has to read them where they actually ship.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "install.sh")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "install-mcp.ps1")); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no checkout root with install.sh and install-mcp.ps1 above %s", dir)
		}
		dir = parent
	}
}
