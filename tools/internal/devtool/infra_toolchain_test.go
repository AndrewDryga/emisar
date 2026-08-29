package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeInfraToolchainFixtures(t *testing.T, terraform, tflint string, pins [][2]string) *App {
	t.Helper()
	root := t.TempDir()
	toolVersions := "erlang 29.0.3\nelixir 1.20.2-otp-29\ngolang 1.26.6\n"
	if terraform != "" {
		toolVersions += "terraform " + terraform + "\n"
	}
	if tflint != "" {
		toolVersions += "tflint " + tflint + "\n"
	}
	if err := os.WriteFile(filepath.Join(root, ".tool-versions"), []byte(toolVersions), 0o600); err != nil {
		t.Fatal(err)
	}
	writeWorkflowPins(t, root, pins)
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckInfraToolchainPins(t *testing.T) {
	validPins := [][2]string{
		{"TERRAFORM_VERSION", testTerraformVersion},
		{"TFLINT_VERSION", "v" + testTflintVersion},
	}
	// The happy path passing is itself proof the tflint tag's leading v is applied:
	// a bare comparison would reject the v-prefixed workflow pin.
	if err := writeInfraToolchainFixtures(t, testTerraformVersion, testTflintVersion, validPins).
		checkInfraToolchainPins(); err != nil {
		t.Fatal(err)
	}

	// .tool-versions moves terraform without the workflow's checksum pin following.
	err := writeInfraToolchainFixtures(t, "1.16.0", testTflintVersion, validPins).checkInfraToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "terraform 1.16.0") {
		t.Fatalf("terraform drift not reported: %v", err)
	}

	err = writeInfraToolchainFixtures(t, testTerraformVersion, "0.63.0", validPins).checkInfraToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "tflint 0.63.0") {
		t.Fatalf("tflint drift not reported: %v", err)
	}

	// A .tool-versions with no terraform pin.
	err = writeInfraToolchainFixtures(t, "", testTflintVersion, validPins).checkInfraToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "does not pin terraform") {
		t.Fatalf("missing terraform pin not reported: %v", err)
	}

	// A workflow missing the checksum pin the gate reads as its reference.
	err = writeInfraToolchainFixtures(t, testTerraformVersion, testTflintVersion,
		[][2]string{{"TFLINT_VERSION", "v" + testTflintVersion}}).checkInfraToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "does not pin TERRAFORM_VERSION") {
		t.Fatalf("missing workflow pin not reported: %v", err)
	}
}
