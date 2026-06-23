package main

import (
	goruntime "runtime"
	"strings"
	"testing"
)

// `emisar version` prints the runner version line plus a go/os/arch line.
// Both come from constants the toolchain knows at build time (Version,
// runtime.Version), so they're deterministic in-process — the VCS lines
// (commit/built/dirty) only appear in a git-built binary and aren't asserted
// here. Driven through the real cobra command; the RunE returns nil and prints
// to os.Stdout, so we capture the process's stdout. closes RUN-030-T01.
func TestVersionCmd_PrintsVersionAndGoLine(t *testing.T) {
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

// `version` does not branch on --json: the human lines are printed whether or
// not the global flag is set (it carries no machine-readable mode). This pins
// the RUN-001-T07 boundary that --json is honored only where a command
// consumes it. closes RUN-030-T04.
func TestVersionCmd_IgnoresJSONFlag(t *testing.T) {
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
	// Still the plain text line, not a JSON object.
	if !strings.Contains(out, "emisar "+Version) {
		t.Fatalf("version must print the plain line even with --json set:\n%s", out)
	}
	if strings.Contains(out, "{") {
		t.Fatalf("version must not emit JSON; --json is a no-op here:\n%s", out)
	}
}
