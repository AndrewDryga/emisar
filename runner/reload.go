package main

import (
	"fmt"
	"io"

	"github.com/andrewdryga/emisar/runner/internal/config"
)

// announceReload tells the operator what happened to the running daemon after
// a pack mutation: signaled to reload (packs re-read, catalog re-advertised),
// or the manual fallback when no live daemon could be reached. cfg may be nil
// (a --dest install can run without one); the config is then resolved
// best-effort from the usual locations.
func announceReload(w io.Writer, cfg *config.Config, manualHint string) {
	if notifyRunnerReload(cfg) {
		fmt.Fprintln(w, "Signaled the runner to reload packs and re-advertise to the control plane.")
	} else {
		fmt.Fprintln(w, manualHint)
	}
}
