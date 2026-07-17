//go:build windows

package main

import "github.com/andrewdryga/emisar/runner/internal/config"

// notifyRunnerReload is a no-op on Windows — there is no SIGHUP to send, so
// pack mutations always fall back to the manual restart hint.
func notifyRunnerReload(_ *config.Config) bool { return false }
