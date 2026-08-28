package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeReleaseToolchainFixtures(t *testing.T, erlang, elixir, otpArg, elixirArg string) *App {
	t.Helper()
	root := t.TempDir()
	toolVersions := "erlang " + erlang + "\nelixir " + elixir + "\ngolang 1.26.6\n"
	if err := os.WriteFile(filepath.Join(root, ".tool-versions"), []byte(toolVersions), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "portal"), 0o755); err != nil {
		t.Fatal(err)
	}
	dockerfile := "ARG ELIXIR_VERSION=" + elixirArg + "\nARG OTP_VERSION=" + otpArg + "\n" +
		"ARG BUILDER_IMAGE=\"hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-x@sha256:abc\"\n"
	if err := os.WriteFile(filepath.Join(root, "portal", "Dockerfile"), []byte(dockerfile), 0o600); err != nil {
		t.Fatal(err)
	}
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
}
