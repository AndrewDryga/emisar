package devtool

import (
	"fmt"
	"path/filepath"
)

// The infra gate installs the terraform and tflint releases whose SHA-256
// checksums the CI workflow pins, while .tool-versions is the version a
// workstation (asdf) and CI both resolve. CI refuses to install unless the two
// agree; hold the same line from the gate so bumping one side without the other
// fails here rather than only after a push. Only CI downloads the binaries, so
// the checksums stay in the workflow and this proves version agreement, not the
// checksum itself — the checksummed download stays CI's job.
func (a *App) checkInfraToolchainPins() error {
	pins, err := readToolVersions(filepath.Join(a.Root, ".tool-versions"))
	if err != nil {
		return fmt.Errorf("read pinned development tools: %w", err)
	}
	// tflint's release tag carries a leading v that .tool-versions omits; the
	// workflow pins the tag, so compare against the same v-prefixed form CI does.
	for _, pin := range []struct{ tool, key, prefix string }{
		{"terraform", "TERRAFORM_VERSION", ""},
		{"tflint", "TFLINT_VERSION", "v"},
	} {
		version := pins[pin.tool]
		if version == "" {
			return fmt.Errorf(".tool-versions does not pin %s", pin.tool)
		}
		want, err := workflowPin(a.Root, pin.key)
		if err != nil {
			return err
		}
		if pin.prefix+version != want {
			return fmt.Errorf(".tool-versions pins %s %s, but the CI workflow checksum-pins %s=%s; "+
				"the gate and CI install the same release — bump .tool-versions and the workflow checksum together",
				pin.tool, version, pin.key, want)
		}
	}
	fmt.Fprintln(a.Out, "verified: .tool-versions terraform and tflint match the CI workflow's checksum-pinned versions")
	return nil
}
