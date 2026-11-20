package main

import (
	"fmt"
	"io"
	goruntime "runtime"
)

// announceReload tells the operator what happened to the running daemon after
// a pack mutation: signaled to reload (packs re-read, catalog re-advertised),
// or the manual fallback when no live daemon could be reached. The config is
// resolved best-effort from the usual locations (a --dest install can run
// without one).
func announceReload(w io.Writer, manualHint string) {
	if notifyRunnerReload(nil) {
		fmt.Fprintln(w, "Signaled the runner to reload packs and re-advertise to the control plane.")
	} else {
		fmt.Fprintln(w, manualHint+": "+manualReloadCommand(goruntime.GOOS))
	}
}

// manualReloadCommand is the command that sends the installed service SIGHUP:
// the launchd job on macOS, the systemd unit elsewhere.
func manualReloadCommand(goos string) string {
	if goos == "darwin" {
		return "sudo launchctl kill SIGHUP system/" + launchdLabel
	}
	return "sudo systemctl reload emisar"
}
