package main

import (
	"bytes"
	"encoding/json"
	goruntime "runtime"
	"strings"
	"testing"
)

// `emisar version` prints the runner version line plus a go/os/arch line.
// Both come from constants the toolchain knows at build time (Version,
// runtime.Version), so they're deterministic in-process — the VCS lines
// (commit/built/dirty) only appear in a git-built binary and aren't asserted
// here. Driven through the real cobra command; the RunE returns nil and prints
// to os.Stdout, so we capture the process's stdout.
func TestVersionCmd_PrintsVersionAndGoLine(t *testing.T) {
	withJSONOut(t, false)
	var err error
	out := captureStdout(t, func() {
		cmd := versionCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(nil)
		err = cmd.Execute()
	})
	if err != nil {
		t.Fatalf("version: %v", err)
	}

	wantVersion := "emisar " + Version
	if !strings.Contains(out, wantVersion) {
		t.Fatalf("output missing version line %q:\n%s", wantVersion, out)
	}
	// The go line carries the toolchain version and this platform's os/arch.
	for _, want := range []string{"go: " + goruntime.Version(), goruntime.GOOS + "/" + goruntime.GOARCH} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
}

// `version --json` answers a fleet inventory: one object with the runner
// version, toolchain, and platform, and no human prose or banner mixed in.
// Decoded as a raw map so the KEYS are pinned, not just the round-trip.
func TestVersionCmd_JSON(t *testing.T) {
	withJSONOut(t, true)
	var err error
	out := captureStdout(t, func() {
		cmd := versionCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		err = cmd.Execute()
	})
	if err != nil {
		t.Fatalf("version --json: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("version --json must emit a JSON object: %v\n%s", err, out)
	}
	want := map[string]any{
		"version": Version,
		"go":      goruntime.Version(),
		"os":      goruntime.GOOS,
		"arch":    goruntime.GOARCH,
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("%s = %#v, want %#v", key, got[key], value)
		}
	}
	// No human line leaks into the machine payload.
	if strings.Contains(out, "emisar "+Version) {
		t.Errorf("--json must replace the human lines, not append to them:\n%s", out)
	}
	// A test binary carries no VCS settings, so the optional fields are absent
	// rather than present-and-empty (the subprocess tests cover a real build).
	for _, optional := range []string{"commit", "built_at", "dirty"} {
		if _, ok := got[optional]; ok {
			t.Errorf("%s must be omitted when the build carries no VCS info: %v", optional, out)
		}
	}
}

// gatherVersionInfo is the single source both renderers read, so the human
// lines can't drift from the JSON: the VCS lines appear exactly when their
// fields are set.
func TestWriteVersion_RendersOptionalVCSLines(t *testing.T) {
	var buf bytes.Buffer
	writeVersion(&buf, versionInfo{
		Version: "1.2.3", Go: "go1.26.5", OS: "linux", Arch: "amd64",
		Commit: "abc123", BuiltAt: "2026-07-31T10:00:00Z", Dirty: true,
	})
	want := "emisar 1.2.3\n" +
		"  go: go1.26.5 linux/amd64\n" +
		"  commit: abc123\n" +
		"  built: 2026-07-31T10:00:00Z\n" +
		"  vcs: dirty (uncommitted changes)\n"
	if got := buf.String(); got != want {
		t.Errorf("human output drifted:\ngot:\n%s\nwant:\n%s", got, want)
	}

	buf.Reset()
	writeVersion(&buf, versionInfo{Version: "1.2.3", Go: "go1.26.5", OS: "linux", Arch: "amd64"})
	want = "emisar 1.2.3\n  go: go1.26.5 linux/amd64\n"
	if got := buf.String(); got != want {
		t.Errorf("a build without VCS info must print only the two lines:\ngot:\n%s\nwant:\n%s", got, want)
	}
}
