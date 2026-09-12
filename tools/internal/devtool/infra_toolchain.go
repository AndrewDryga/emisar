package devtool

import (
	"context"
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

// Agreeing pins only promise the version CI installs; the gate still lints with
// whatever terraform and tflint PATH resolves, and an older tflint quietly
// misses the rules the pinned release enforces. Run the binaries the following
// phases will run and refuse the gate when either is not the pinned release, so
// a local green means the same linter CI ran.
func (a *App) checkInfraToolVersions(ctx context.Context) error {
	pins, err := readToolVersions(filepath.Join(a.Root, ".tool-versions"))
	if err != nil {
		return fmt.Errorf("read pinned development tools: %w", err)
	}
	for _, tool := range infraPinnedTools {
		want := pins[tool.Pin]
		if want == "" {
			return fmt.Errorf(".tool-versions does not pin %s", tool.Pin)
		}
		output, outputErr := a.output(ctx, a.Root, nil, tool.Command, tool.Args...)
		if outputErr != nil {
			return fmt.Errorf("%s %s is required to run the infra gate: %w; run './run bootstrap'", tool.Name, want, outputErr)
		}
		if actual := tool.Parse(string(output)); actual != want {
			return fmt.Errorf("%s on PATH is %s, but .tool-versions pins %s; "+
				"the gate must run the release CI installs — run './run bootstrap'", tool.Name, actual, want)
		}
		fmt.Fprintf(a.Out, "verified: %s %s on PATH matches the .tool-versions pin\n", tool.Name, want)
	}
	return nil
}
