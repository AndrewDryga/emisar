package devtool

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testBuilderDigest    = "@sha256:23953ce7850433f8f650f4b710d8b35d8d495092371ffda0356ea9bc80953151"
	testHexVersion       = "2.5.1"
	testRebar3Version    = "3.27.0"
	testRebar3SHA512     = "0d00494d849fdc521a55142278d1f6ba552954fbd65b80d40df8022f594f05d6c99ed1d731bc263691a04176e11d4c6e126c56ba20dca19c5e42d4ffab2e7e36"
	testTerraformVersion = "1.15.8"
	testTflintVersion    = "0.64.0"
)

// writeWorkflowPins writes a minimal ci.yml carrying only the pinned env keys the
// toolchain checks read, so a test can drift one pin without a whole workflow.
func writeWorkflowPins(t *testing.T, root string, pins [][2]string) {
	t.Helper()
	dir := filepath.Join(root, ".github", "workflows")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var body strings.Builder
	body.WriteString("jobs:\n  probe:\n    env:\n")
	for _, pin := range pins {
		fmt.Fprintf(&body, "      %s: %s\n", pin[0], pin[1])
	}
	if err := os.WriteFile(filepath.Join(dir, "ci.yml"), []byte(body.String()), 0o600); err != nil {
		t.Fatal(err)
	}
}

// validWorkflowPins mirrors the real ci.yml: hex version quoted, sha512 bare,
// terraform bare, and the tflint tag carrying its leading v.
func validWorkflowPins() [][2]string {
	return [][2]string{
		{"HEX_VERSION", `"` + testHexVersion + `"`},
		{"REBAR3_VERSION", `"` + testRebar3Version + `"`},
		{"REBAR3_SHA512", testRebar3SHA512},
		{"TERRAFORM_VERSION", testTerraformVersion},
		{"TFLINT_VERSION", "v" + testTflintVersion},
	}
}

func hexRebarARGs() string {
	return "ARG HEX_VERSION=" + testHexVersion +
		"\nARG REBAR3_VERSION=" + testRebar3Version +
		"\nARG REBAR3_SHA512=" + testRebar3SHA512 + "\n"
}

// validBuilderDockerfile is a Dockerfile whose elixir/otp/builder pins pass, so a
// test can vary only the hex/rebar3 ARGs it wants to exercise.
func validBuilderDockerfile() string {
	return "ARG ELIXIR_VERSION=1.20.2\nARG OTP_VERSION=29.0.3\n" +
		"ARG BUILDER_IMAGE=\"hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-x" + testBuilderDigest + "\"\n"
}

func writeReleaseToolchainFixtures(t *testing.T, erlang, elixir, otpArg, elixirArg string) *App {
	t.Helper()
	return writeReleaseToolchainDockerfile(t, erlang, elixir,
		"ARG ELIXIR_VERSION="+elixirArg+"\nARG OTP_VERSION="+otpArg+"\n"+
			"ARG BUILDER_IMAGE=\"hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-x"+testBuilderDigest+"\"\n"+
			hexRebarARGs())
}

func writeReleaseToolchainDockerfile(t *testing.T, erlang, elixir, dockerfile string) *App {
	t.Helper()
	root := t.TempDir()
	toolVersions := "erlang " + erlang + "\nelixir " + elixir + "\ngolang 1.26.6\n"
	if err := os.WriteFile(filepath.Join(root, ".tool-versions"), []byte(toolVersions), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "portal"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "portal", "Dockerfile"), []byte(dockerfile), 0o600); err != nil {
		t.Fatal(err)
	}
	writeWorkflowPins(t, root, validWorkflowPins())
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckReleaseToolchainPins(t *testing.T) {
	if err := writeReleaseToolchainFixtures(t, "29.0.3", "1.20.2-otp-29", "29.0.3", "1.20.2").
		checkReleaseToolchainPins(); err != nil {
		t.Fatal(err)
	}

	// The dangerous direction: .tool-versions moves, dev and CI upgrade, and
	// the release image silently keeps building from the old pinned digest.
	err := writeReleaseToolchainFixtures(t, "29.0.4", "1.20.2-otp-29", "29.0.3", "1.20.2").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "OTP_VERSION=29.0.3") {
		t.Fatalf("OTP drift not reported: %v", err)
	}

	err = writeReleaseToolchainFixtures(t, "29.0.3", "1.21.0-otp-29", "29.0.3", "1.20.2").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "ELIXIR_VERSION=1.20.2") {
		t.Fatalf("Elixir drift not reported: %v", err)
	}

	err = writeReleaseToolchainFixtures(t, "", "", "29.0.3", "1.20.2").
		checkReleaseToolchainPins()
	if err == nil {
		t.Fatal("missing pins not reported")
	}

	// A BUILDER_IMAGE whose tag is hardcoded rather than interpolated from the
	// ARGs passes the ARG-default checks but builds a toolchain the ARGs no
	// longer describe.
	err = writeReleaseToolchainDockerfile(t, "29.0.3", "1.20.2-otp-29",
		"ARG ELIXIR_VERSION=1.20.2\nARG OTP_VERSION=29.0.3\n"+
			"ARG BUILDER_IMAGE=\"hexpm/elixir:1.20.2-erlang-29.0.3-debian-x"+testBuilderDigest+"\"\n").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "does not interpolate ${ELIXIR_VERSION}") {
		t.Fatalf("hardcoded builder tag not reported: %v", err)
	}

	// A BUILDER_IMAGE with no digest is a mutable tag, not the reviewed pin.
	err = writeReleaseToolchainDockerfile(t, "29.0.3", "1.20.2-otp-29",
		"ARG ELIXIR_VERSION=1.20.2\nARG OTP_VERSION=29.0.3\n"+
			"ARG BUILDER_IMAGE=\"hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-x\"\n").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "not digest-pinned") {
		t.Fatalf("undigested builder image not reported: %v", err)
	}

	// The Dockerfile's hex pin drifts from the version CI installs for the portal
	// gate, so the release image would build hex the gate never exercised.
	err = writeReleaseToolchainDockerfile(t, "29.0.3", "1.20.2-otp-29",
		validBuilderDockerfile()+
			"ARG HEX_VERSION=2.5.0\nARG REBAR3_VERSION="+testRebar3Version+"\nARG REBAR3_SHA512="+testRebar3SHA512+"\n").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "HEX_VERSION=2.5.0") {
		t.Fatalf("hex drift not reported: %v", err)
	}

	// A malformed rebar3 checksum is rejected as not-well-formed before it could
	// reach the image's sha512 verification.
	err = writeReleaseToolchainDockerfile(t, "29.0.3", "1.20.2-otp-29",
		validBuilderDockerfile()+
			"ARG HEX_VERSION="+testHexVersion+"\nARG REBAR3_VERSION="+testRebar3Version+"\nARG REBAR3_SHA512=nothex\n").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "REBAR3_SHA512=nothex is not") {
		t.Fatalf("malformed rebar3 checksum not reported: %v", err)
	}

	// A missing hex ARG default is reported by name.
	err = writeReleaseToolchainDockerfile(t, "29.0.3", "1.20.2-otp-29",
		validBuilderDockerfile()+
			"ARG REBAR3_VERSION="+testRebar3Version+"\nARG REBAR3_SHA512="+testRebar3SHA512+"\n").
		checkReleaseToolchainPins()
	if err == nil || !strings.Contains(err.Error(), "does not default ARG HEX_VERSION") {
		t.Fatalf("missing hex ARG not reported: %v", err)
	}
}
