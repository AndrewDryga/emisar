package main

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
)

// TestJSONPayloadKeysAreFrozen pins the exact top-level key set of every
// operator-facing --json payload.
//
// compatibility.md freezes "the structured output --json emits", and a script
// reads these keys by name — but the CLI surface golden records only commands
// and flags, so until this test existed a rename inside one of these structs
// was invisible to every gate. Each case marshals a fully-populated value, so
// the optional keys are pinned alongside the required ones.
//
// Changing a key here is a compatibility event, not a refactor: after 1.0 add a
// key, never rename or drop one.
func TestJSONPayloadKeysAreFrozen(t *testing.T) {
	dirty := true
	connected := time.Unix(0, 0).UTC()

	for _, tc := range []struct {
		name    string
		payload any
		want    []string
	}{
		{
			name:    "version",
			payload: versionInfo{Version: "1", Go: "go1", OS: "linux", Arch: "amd64", Commit: "c", BuiltAt: "t", Dirty: &dirty},
			want:    []string{"arch", "built_at", "commit", "dirty", "go", "os", "version"},
		},
		{
			name:    "doctor",
			payload: doctorReport{Status: "ok", Checks: []doctorCheck{}},
			want:    []string{"checks", "failed", "passed", "status", "warned"},
		},
		{
			name:    "doctor check",
			payload: doctorCheck{Name: "config", Status: "ok", Detail: "d"},
			want:    []string{"detail", "name", "status"},
		},
		{
			name:    "status",
			payload: statusReport{Status: "ok", Runtime: &cloud.RuntimeStatus{}, Checks: []doctorCheck{}},
			want:    []string{"checks", "failed", "passed", "runtime", "status", "warned"},
		},
		{
			name:    "audit verify",
			payload: auditVerifyResult{Path: "p", Intact: false, Error: "e"},
			want:    []string{"error", "intact", "path"},
		},
		{
			name:    "runtime status",
			payload: cloud.RuntimeStatus{ConnectedAt: &connected, LastHeartbeatSentAt: &connected},
			want: []string{
				"actions", "advertisement_pending", "connected_at", "connection_attempts",
				"degraded_packs", "heartbeat_every_seconds", "inflight_runs",
				"last_heartbeat_sent_at", "packs", "pid", "schema_version", "started_at",
				"state", "unavailable_actions", "updated_at",
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, err := json.Marshal(tc.payload)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			var decoded map[string]any
			if err := json.Unmarshal(body, &decoded); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			got := make([]string, 0, len(decoded))
			for key := range decoded {
				got = append(got, key)
			}
			sort.Strings(got)
			if strings.Join(got, ",") != strings.Join(tc.want, ",") {
				t.Errorf("keys = %v, want %v", got, tc.want)
			}
		})
	}
}

// A clean build must say so rather than fall silent: with a plain bool and
// omitempty, "clean" and "the toolchain reported no VCS state" were the same
// absent key, so a fleet asking whether any host runs a modified binary could
// not tell no from cannot-say.
func TestVersionInfoReportsACleanBuildExplicitly(t *testing.T) {
	clean := false
	body, err := json.Marshal(versionInfo{Version: "1", Dirty: &clean})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"dirty":false`) {
		t.Errorf("a clean VCS build must emit dirty:false, got %s", body)
	}
	body, err = json.Marshal(versionInfo{Version: "1"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(body), "dirty") {
		t.Errorf("a build with no VCS stamp must omit dirty, got %s", body)
	}
}
