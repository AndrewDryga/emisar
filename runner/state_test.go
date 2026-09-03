package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStateCheckDispatchLogCmdReportsVersionedAndOlderState(t *testing.T) {
	tests := []struct {
		name       string
		contents   string
		legacy     string
		wantOutput string
		wantError  string
	}{
		{
			name: "older snapshot is migratable",
			contents: `{"request_id":"req","result":{"type":"action_result","protocol_version":1,"request_id":"req","status":"success"}}` +
				"\n",
			wantOutput: "older dispatch state; connect migrates it forward",
		},
		{
			name:       "v2 journal is healthy",
			contents:   `{"format":"emisar_dispatch_log","version":2}` + "\n",
			wantOutput: "ok: 0 entries",
		},
		{
			name:      "torn v2 journal fails closed",
			contents:  `{"format":"emisar_dispatch_log","version":2}`,
			legacy:    `{"request_id":"stale","result":{"type":"action_result","protocol_version":1,"request_id":"stale","status":"success"}}` + "\n",
			wantError: "quarantining forgets replay history and may allow a redelivered action to run again",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dataDir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dataDir, "dispatches.jsonl"), []byte(test.contents), 0o600); err != nil {
				t.Fatal(err)
			}
			if test.legacy != "" {
				if err := os.WriteFile(filepath.Join(dataDir, "dedup.jsonl"), []byte(test.legacy), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			var output bytes.Buffer
			cmd := stateCheckDispatchLogCmd()
			cmd.SetOut(&output)
			cmd.SetArgs([]string{"--data-dir", dataDir})
			err := cmd.Execute()
			if test.wantError != "" {
				if err == nil || !strings.Contains(strings.ToLower(err.Error()), test.wantError) {
					t.Fatalf("error = %v, want %q", err, test.wantError)
				}
				if !strings.Contains(err.Error(), "stop the runner and prove it is idle") ||
					!strings.Contains(err.Error(), filepath.Join(dataDir, "dedup.jsonl")) {
					t.Fatalf("error omits safe two-path quarantine boundary: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), test.wantOutput) {
				t.Fatalf("output = %q, want %q", output.String(), test.wantOutput)
			}
			if test.name == "v2 journal is healthy" && strings.Contains(output.String(), "migrates") {
				t.Fatalf("healthy v2 output claims migration: %q", output.String())
			}
		})
	}
}

func TestStateCheckDispatchLogCmdBindsExplicitDataDirToConfig(t *testing.T) {
	withFlags(t)
	root := t.TempDir()
	configured := filepath.Join(root, "data")
	other := filepath.Join(root, "other-data")
	for _, dir := range []string{configured, other} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	flagConfig = writeMinimalConfig(t, root, filepath.Join(root, "packs"))

	cmd := stateCheckDispatchLogCmd()
	cmd.SetArgs([]string{"--data-dir", other})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "does not match configured paths.data_dir") {
		t.Fatalf("mismatched config/data error = %v", err)
	}

	cmd = stateCheckDispatchLogCmd()
	cmd.SetArgs([]string{"--data-dir", configured})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("matching config/data: %v", err)
	}
}

// `emisar state` builds the runner_state advertisement from config + the
// loaded registry + admission and prints it as JSON. This drives the real
// command (read-only load → StateBuilder → printJSON) against a temp config + a
// one-action pack and asserts the advertised shape: identity from config,
// the loaded pack and its action present.
func TestStateCmd_PrintsAdvertisedState(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)

	var execErr error
	out := captureStdout(t, func() {
		cmd := stateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("state: %v", execErr)
	}

	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("state output is not JSON: %v\n%s", err, out)
	}
	if st["type"] != "runner_state" {
		t.Fatalf("type = %v, want runner_state", st["type"])
	}
	if st["group"] != "test" {
		t.Fatalf("group = %v, want the configured group %q", st["group"], "test")
	}
	if _, ok := st["packs"].(map[string]any)["linux"]; !ok {
		t.Fatalf("advertised packs should include the loaded pack:\n%s", out)
	}
	actions, _ := st["actions"].([]any)
	if len(actions) != 1 {
		t.Fatalf("want exactly the one loaded action, got %d:\n%s", len(actions), out)
	}
	if first, _ := actions[0].(map[string]any); first["id"] != "linux.ping" {
		t.Fatalf("advertised action id = %v, want linux.ping", first["id"])
	}
}

// Empty registry: with a packs dir holding no packs, `state` still builds a
// valid runner_state — identity + group present, but the actions list empty and
// the packs map empty/absent. A runner with nothing installed advertises an
// identity-only catalog, not an error.
func TestStateCmd_EmptyRegistryIdentityOnly(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	emptyPacks := dir + "/packs"
	if err := os.MkdirAll(emptyPacks, 0o755); err != nil {
		t.Fatal(err)
	}
	flagConfig = writeMinimalConfig(t, dir, emptyPacks)

	var execErr error
	out := captureStdout(t, func() {
		cmd := stateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("state: %v", execErr)
	}

	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("state output is not JSON: %v\n%s", err, out)
	}
	// Runtime metadata is still advertised.
	if st["type"] != "runner_state" || st["group"] != "test" {
		t.Fatalf("runtime state should still be present: type=%v group=%v", st["type"], st["group"])
	}
	// No actions, and no non-empty packs map (omitempty may drop it entirely).
	if actions, _ := st["actions"].([]any); len(actions) != 0 {
		t.Fatalf("empty registry must advertise zero actions, got %d:\n%s", len(actions), out)
	}
	if pk, ok := st["packs"].(map[string]any); ok && len(pk) != 0 {
		t.Fatalf("empty registry must advertise no packs, got %v:\n%s", pk, out)
	}
}

func TestStateCmd_DoesNotPersistRuntimeStateAndAdvertisesSigningPolicy(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)
	caKey, err := generateSigningKey(algEd25519)
	if err != nil {
		t.Fatal(err)
	}
	caDER, err := mintCA(caKey, "k1", 365*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	var anchor strings.Builder
	anchor.WriteString("cloud:\n  url: wss://portal.example/socket\n  enrollment_key_env: EMISAR_ENROLLMENT_KEY\n")
	anchor.WriteString("signing:\n  enforce_signatures: true\n  trusted_cas:\n    - name: k1\n      pem: |\n")
	for _, line := range strings.Split(strings.TrimRight(encodeCertPEM(caDER), "\n"), "\n") {
		anchor.WriteString("        " + line + "\n")
	}
	extra := anchor.String()
	if err := appendToFile(t, flagConfig, extra); err != nil {
		t.Fatal(err)
	}

	var execErr error
	out := captureStdout(t, func() {
		cmd := stateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("state: %v", execErr)
	}

	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("state output is not JSON: %v\n%s", err, out)
	}
	if _, ok := st["runner_id"]; ok {
		t.Fatalf("runner_id duplicates the authenticated socket identity: %s", out)
	}
	path := filepath.Join(dir, "events.jsonl")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("state command created runtime file %s: %v", path, err)
	}
	if st["enforce_signatures"] != true {
		t.Fatalf("state must advertise configured signature enforcement:\n%s", out)
	}
	caIDs, _ := st["signing_ca_ids"].([]any)
	if len(caIDs) != 1 || caIDs[0] != "k1" {
		t.Fatalf("signing_ca_ids = %v, want [k1]", caIDs)
	}
}
