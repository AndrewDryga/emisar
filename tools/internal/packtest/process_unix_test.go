//go:build !windows

package packtest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestExecuteKillsTimedOutCommandDescendants is the containment half of the
// deadline. Returning on time is not enough: a case that timed out is about to
// have its disposable fixture torn down and re-arranged, so a descendant still
// running against that fixture corrupts whatever runs next. The evidence is the
// descendant's own pid — a bounded WaitDelay would make execute return just as
// promptly while leaving that process alive.
func TestExecuteKillsTimedOutCommandDescendants(t *testing.T) {
	previous := commandTimeout
	commandTimeout = 100 * time.Millisecond
	t.Cleanup(func() { commandTimeout = previous })

	root := t.TempDir()
	pidFile := filepath.Join(root, "pid")
	marker := filepath.Join(root, "mutated")

	// The inner shell inherits the command's stdout/stderr pipes, so it is
	// exactly the process that used to hold Wait open. `$!` is the only
	// reliable way to publish its pid: POSIX `$$` inside a subshell still
	// names the parent.
	// The 3s sleep is the margin: the group signal lands with the 100ms
	// deadline, so only a host that stalled for most of three seconds between
	// the two could let the mutation through.
	program := "/bin/sh -c 'sleep 3; : > " + marker + "' & echo $! > " + pidFile + "; wait"

	start := time.Now()
	_, err := execute([]string{"/bin/sh", "-c", program}, os.Environ())
	if err == nil || !strings.Contains(err.Error(), "command timed out after 100ms") {
		t.Fatalf("execute error = %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("execute returned after %s, deadline was %s", elapsed, commandTimeout)
	}

	pid := descendantPID(t, pidFile)
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	// This window also outlasts the descendant's own sleep, so a survivor is
	// caught either by this poll or by the marker it would then write.
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("descendant pid %d still alive 5s after the command timed out", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Independent of the pid check: let the moment the descendant would have
	// mutated the fixture pass, then confirm it never did.
	time.Sleep(time.Until(start.Add(3500 * time.Millisecond)))
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("timed-out descendant mutated its fixture: stat %s = %v", marker, err)
	}
}

// TestExecuteBoundsWaitOnDescendantsHoldingOutput covers what the process group
// does not: a command that itself finishes inside the deadline but leaves
// something holding the output pipes. os/exec stops watching the context the
// moment the leader is reaped, so cancellation never fires — only the finite
// WaitDelay ends the wait. A pack hits this by backgrounding a helper without
// redirecting its output; the error has to say that rather than blame a
// deadline that never expired.
//
// Returning on time is only half of it. This step has failed, and the case that
// owns it is about to have its disposable fixture torn down and re-arranged, so
// the descendant that held the output must not outlive the failure either. The
// evidence is its own pid plus the marker it would write three seconds later:
// the drain cap alone bounds the return while leaving that process running.
func TestExecuteBoundsWaitWhenLeaderExitsHoldingOutput(t *testing.T) {
	previousDelay := waitDelay
	waitDelay = 200 * time.Millisecond
	t.Cleanup(func() { waitDelay = previousDelay })
	previousTimeout := commandTimeout
	commandTimeout = 30 * time.Second
	t.Cleanup(func() { commandTimeout = previousTimeout })

	root := t.TempDir()
	pidFile := filepath.Join(root, "pid")
	marker := filepath.Join(root, "mutated")
	cleanupDescendant(t, pidFile)

	// The held-open sleep still runs far past the cap, so the elapsed bound
	// below stays about the cap and not about the descendant finishing. The
	// mutation sits 3s in: the group signal lands with the 200ms cap, so only a
	// host that stalled for most of three seconds could let it through.
	program := "/bin/sh -c 'sleep 3; : > " + marker + "; sleep 30' & echo $! > " + pidFile + "; exit 0"

	start := time.Now()
	result, err := execute([]string{"/bin/sh", "-c", program}, os.Environ())
	elapsed := time.Since(start)

	// The descendant holds the pipe for 33s; anything near that is Wait
	// blocking on it rather than the cap ending the drain.
	if elapsed > 5*time.Second {
		t.Fatalf("execute returned after %s, WaitDelay was %s", elapsed, waitDelay)
	}
	// Not the timeout error: the deadline never fired, the drain cap did.
	if err == nil || !strings.Contains(err.Error(), "held its output past 200ms") {
		t.Fatalf("execute error = %v, result = %+v", err, result)
	}

	pid := descendantPID(t, pidFile)
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("descendant pid %d still alive 5s after the drain cap failed the step", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Independent of the pid check: let the moment the descendant would have
	// mutated the fixture pass, then confirm it never did.
	time.Sleep(time.Until(start.Add(3500 * time.Millisecond)))
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("descendant that failed the drain mutated its fixture: stat %s = %v", marker, err)
	}
}

// TestExecuteKeepsSuccessfulBackgroundHelpersAlive is the limit on that
// cleanup. An arrange step that deliberately backgrounds a helper redirects its
// output, so the leader's exit closes the pipes, Wait returns cleanly, and the
// helper is meant to outlive the step and serve the case that follows. The
// cleanup belongs to the failed drain alone; killing every command's group on
// the way out would tear those helpers down.
func TestExecuteKeepsSuccessfulBackgroundHelpersAlive(t *testing.T) {
	previousDelay := waitDelay
	waitDelay = 200 * time.Millisecond
	t.Cleanup(func() { waitDelay = previousDelay })
	previousTimeout := commandTimeout
	commandTimeout = 30 * time.Second
	t.Cleanup(func() { commandTimeout = previousTimeout })

	root := t.TempDir()
	pidFile := filepath.Join(root, "pid")
	marker := filepath.Join(root, "arranged")
	cleanupDescendant(t, pidFile)

	// Output redirected to a file, exactly as a pack backgrounds a helper: the
	// inherited pipes close with the leader, so this is the success path.
	program := "/bin/sh -c 'sleep 1; : > " + marker + "; sleep 30' > /dev/null 2>&1 & " +
		"echo $! > " + pidFile + "; echo arranged; exit 0"

	start := time.Now()
	result, err := execute([]string{"/bin/sh", "-c", program}, os.Environ())
	if err != nil {
		t.Fatalf("execute error = %v, result = %+v", err, result)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("execute returned after %s; the redirected helper should not hold the drain", elapsed)
	}
	if result.exitCode != 0 || !strings.Contains(result.stdout, "arranged") {
		t.Fatalf("execute result = %+v", result)
	}

	// The helper's own work lands a second later. It has to still be there to
	// do it, and the marker is the state the next step would depend on.
	pid := descendantPID(t, pidFile)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, statErr := os.Stat(marker); statErr == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("backgrounded helper pid %d never arranged %s", pid, marker)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("backgrounded helper pid %d did not survive its successful step: %v", pid, err)
	}
}

// TestExecuteBoundsTimeoutWhenDescendantLeavesTheGroup is why a group kill on
// its own is not enough. A descendant that called setsid is in neither the
// command's group nor the harness's, so the deadline's signal cannot reach it
// and it keeps the inherited output pipes open after everything the signal did
// reach is gone. Only the finite WaitDelay ends that wait, and the command
// still has to report the timeout it actually hit.
func TestExecuteBoundsTimeoutWhenDescendantLeavesTheGroup(t *testing.T) {
	setsid, err := exec.LookPath("setsid")
	if err != nil {
		t.Skip("setsid is not available on this platform")
	}
	previousDelay := waitDelay
	waitDelay = 200 * time.Millisecond
	t.Cleanup(func() { waitDelay = previousDelay })
	previousTimeout := commandTimeout
	commandTimeout = 300 * time.Millisecond
	t.Cleanup(func() { commandTimeout = previousTimeout })

	root := t.TempDir()
	pidFile := filepath.Join(root, "pid")
	cleanupDescendant(t, pidFile)

	// The leader stays alive past the deadline, so cancellation really does
	// fire and really does miss the escaped grandchild.
	program := setsid + " /bin/sh -c 'sleep 30' & echo $! > " + pidFile + "; sleep 30"

	start := time.Now()
	result, err := execute([]string{"/bin/sh", "-c", program}, os.Environ())
	elapsed := time.Since(start)

	if elapsed > 5*time.Second {
		t.Fatalf("execute returned after %s, deadline %s + WaitDelay %s",
			elapsed, commandTimeout, waitDelay)
	}
	if err == nil || !strings.Contains(err.Error(), "command timed out after 300ms") {
		t.Fatalf("execute error = %v, result = %+v", err, result)
	}
}

// cleanupDescendant kills whatever pid the fixture published, so a test that
// fails its assertion still does not leak a 30-second sleep into the gate.
func cleanupDescendant(t *testing.T, pidFile string) {
	t.Helper()
	t.Cleanup(func() {
		if pid := descendantPIDIfWritten(pidFile); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
}

func descendantPID(t *testing.T, pidFile string) int {
	t.Helper()
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatalf("read descendant pid: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		t.Fatalf("descendant pid file = %q (%v)", raw, err)
	}
	return pid
}

func descendantPIDIfWritten(pidFile string) int {
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		return 0
	}
	return pid
}
