package browser

import (
	"fmt"
	"os"
	"os/exec"
)

// A lifeline ties a launched Chromium tree's lifetime to its owning process in a way the KERNEL
// enforces. Pdeathsig cannot: it applies to the immediate child only and is not inherited across
// fork, and chromium-headless-shell forks the real browser process — measured in the box image on
// 2026-08-01, an isolated session survived its owner's SIGKILL despite chromedp's default
// Pdeathsig. Go-side cleanup cannot either: no defer or Cancel hook runs on SIGKILL, and go test's
// -timeout SIGQUIT skips defers the same way. Every leak reached a coop box's descendant drain,
// which un-completes the finished task and re-runs it.
//
// The mechanism: the owner holds the write end of a pipe it never writes to; the browser runs
// under a tiny wrapper that starts Chromium in the wrapper's own process group plus a watchdog
// blocked reading the pipe's inherited read end (fd 3). When the owner dies — any way, including
// SIGKILL — the kernel closes the write end, the watchdog sees EOF and SIGKILLs the wrapper's
// group, taking Chromium and every forked helper with it. Closing the write end explicitly
// (Session.Close, daemon shutdown) triggers the same reaping as a belt.
//
// When Chromium exits on its own, the wrapper reaps the watchdog and propagates the exit status,
// so nothing lingers to hold a box open.
const lifelineScript = `bin="$1"; shift
"$bin" "$@" &
c=$!
(
  while IFS= read -r _ <&3; do :; done
  kill -s KILL -- -$$ 2>/dev/null
) &
g=$!
wait "$c"
s=$?
kill "$g" 2>/dev/null
exit "$s"`

// newLifeline returns the owner-held write end and the wrapper's read end. The owner keeps `keep`
// open for the browser's whole lifetime — closing it kills the tree — and closes `child` once the
// command has started.
func newLifeline() (keep, child *os.File, err error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, fmt.Errorf("browser lifeline: %w", err)
	}
	return w, r, nil
}

// wrapWithLifeline rewrites cmd to run through the lifeline wrapper. It replaces any SysProcAttr:
// the wrapper must lead its own process group so the watchdog's one group kill covers Chromium and
// all its forked helpers. Callers that record cmd.Process.Pid get the wrapper (= group leader).
func wrapWithLifeline(cmd *exec.Cmd, child *os.File) {
	cmd.Args = append([]string{"/bin/sh", "-c", lifelineScript, "chromium-lifeline"}, cmd.Args...)
	cmd.Path = "/bin/sh"
	cmd.ExtraFiles = append(cmd.ExtraFiles, child) // fd 3 in the wrapper
	cmd.SysProcAttr = browserSysProcAttr()
}
