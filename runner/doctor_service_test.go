package main

import (
	"strings"
	"testing"
)

func TestSystemdServiceResult(t *testing.T) {
	for _, tt := range []struct {
		name       string
		active     string
		enabled    string
		wantStatus checkStatus
		wantDetail string
	}{
		{"active and enabled is healthy", "active", "enabled", checkOK, "active, enabled at boot"},
		{"active but disabled warns about reboots", "active", "disabled", checkWarn, "sudo systemctl enable emisar"},
		{"inactive warns with the start command", "inactive", "enabled", checkWarn, "sudo systemctl start emisar"},
		{"failed warns with the start command", "failed", "enabled", checkWarn, "systemd: failed"},
		{"unknown state still warns", "unknown", "unknown", checkWarn, "systemd: unknown"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			result := systemdServiceResult(tt.active, tt.enabled)

			if result.name != "service" {
				t.Errorf("name = %q, want %q", result.name, "service")
			}
			if result.status != tt.wantStatus {
				t.Errorf("status = %v, want %v", result.status, tt.wantStatus)
			}
			if !strings.Contains(result.detail, tt.wantDetail) {
				t.Errorf("detail = %q, want it to contain %q", result.detail, tt.wantDetail)
			}
		})
	}
}

func TestLaunchdServiceResult(t *testing.T) {
	loaded := launchdServiceResult(true)
	if loaded.status != checkOK || !strings.Contains(loaded.detail, "loaded") {
		t.Errorf("loaded = %+v, want an OK loaded line", loaded)
	}

	unloaded := launchdServiceResult(false)
	if unloaded.status != checkWarn || !strings.Contains(unloaded.detail, "launchctl bootstrap") {
		t.Errorf("unloaded = %+v, want a warn with the bootstrap command", unloaded)
	}
}
