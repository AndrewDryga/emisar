//go:build linux

package executor

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
)

// The kernel is the only authority on whether no_new_privs took, so these read
// it back out of the child rather than asserting we called the right function.
//
// They are gated on the process not already having it. A hardened container —
// the Coop box, and any Docker run with --security-opt=no-new-privileges — sets
// no_new_privs for everything inside it, so a child there reports 1 whether or
// not startCommand did anything. Asserting the child is 1 in that environment
// is a test that cannot fail, which is worse than no test: it was written that
// way first and passed with the prctl deleted.
//
// The baseline comes from /proc/self/status, which reports the main thread —
// never a pooled thread a previous startCommand left carrying the bit.

func TestStartCommand_ChildInheritsNoNewPrivs(t *testing.T) {
	requireNoAmbientNoNewPrivs(t)

	out := runAndCapture(t, "grep ^NoNewPrivs /proc/self/status")
	if got := strings.TrimSpace(out); got != "NoNewPrivs:\t1" {
		t.Fatalf("child reported %q, want NoNewPrivs:\t1 — a setuid binary could still escalate", got)
	}
}

// The flag has to survive the exec chain too, or a pack whose action is a shell
// pipeline would lose it at the first child: no_new_privs is preserved across
// execve and inherited by grandchildren, and that is the property that makes it
// worth setting at all.
func TestStartCommand_NoNewPrivsSurvivesNestedExec(t *testing.T) {
	requireNoAmbientNoNewPrivs(t)

	out := runAndCapture(t, "sh -c 'grep ^NoNewPrivs /proc/self/status'")
	if got := strings.TrimSpace(out); got != "NoNewPrivs:\t1" {
		t.Fatalf("grandchild reported %q, want NoNewPrivs:\t1", got)
	}
}

// Regression guard for the Pdeathsig hazard. Pdeathsig fires when the FORKING
// THREAD exits, not the process, so an implementation that forks from a thread
// it then retires kills every action the instant it starts. This runs a command
// through the full executor path and requires it to produce output, which it
// cannot do if it was signalled at birth. Unlike the two above, it is valid in
// any environment.
func TestStartCommand_ChildSurvivesItsForkingThread(t *testing.T) {
	out := runAndCapture(t, "echo alive")
	if strings.TrimSpace(out) != "alive" {
		t.Fatalf("child produced %q — it was killed before it could run", out)
	}
}

// Captured once, on the first call, which is before any test in this file has
// run startCommand. It has to be latched: startCommand locks whichever thread
// its caller happens to be on, and that can be the main thread, after which
// /proc/self/status reports 1 and every later test skips itself for the wrong
// reason. Re-reading per test made the nested-exec case skip whenever it ran
// second.
var ambientNoNewPrivs = sync.OnceValues(func() (bool, error) {
	status, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(status), "\n") {
		if after, found := strings.CutPrefix(line, "NoNewPrivs:"); found {
			return strings.TrimSpace(after) == "1", nil
		}
	}
	return false, errors.New("/proc/self/status does not report NoNewPrivs on this kernel")
})

func requireNoAmbientNoNewPrivs(t *testing.T) {
	t.Helper()
	ambient, err := ambientNoNewPrivs()
	if err != nil {
		t.Skipf("cannot determine ambient no_new_privs: %v", err)
	}
	if ambient {
		t.Skip("this process already has no_new_privs, so a child inherits it either way — " +
			"run on a host without it (not a hardened container) to exercise this")
	}
}

func runAndCapture(t *testing.T, script string) string {
	t.Helper()
	stdout, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatal(err)
	}
	defer stdout.Close()

	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.Stdout = stdout
	applyProcAttr(cmd)
	if err := startCommand(cmd); err != nil {
		t.Fatalf("startCommand: %v", err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child exited with %v", err)
	}
	data, err := os.ReadFile(stdout.Name())
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
