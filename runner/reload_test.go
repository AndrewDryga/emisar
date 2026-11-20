package main

import "testing"

// The manual reload hint must name the supervisor install.sh set up on that
// platform: a launchd job on macOS, the systemd unit on Linux.
func TestManualReloadCommandMatchesSupervisor(t *testing.T) {
	for goos, want := range map[string]string{
		"linux":  "sudo systemctl reload emisar",
		"darwin": "sudo launchctl kill SIGHUP system/com.emisar.runner",
	} {
		t.Run(goos, func(t *testing.T) {
			if got := manualReloadCommand(goos); got != want {
				t.Errorf("manualReloadCommand(%q) = %q, want %q", goos, got, want)
			}
		})
	}
}
