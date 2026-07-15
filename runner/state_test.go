package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
	extra := "cloud:\n  url: wss://portal.example/socket\n  auth_key_env: EMISAR_AUTH_KEY\n" +
		"signing:\n  enforce_signatures: true\n  trusted_cas:\n" +
		"    - ca_id: k1\n      public_key: " + strings.Repeat("ab", 32) + "\n"
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
	for _, path := range []string{
		filepath.Join(dir, "data", "runner_id"),
		filepath.Join(dir, "events.jsonl"),
	} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("state command created runtime file %s: %v", path, err)
		}
	}
	if st["enforce_signatures"] != true {
		t.Fatalf("state must advertise configured signature enforcement:\n%s", out)
	}
	caIDs, _ := st["signing_ca_ids"].([]any)
	if len(caIDs) != 1 || caIDs[0] != "k1" {
		t.Fatalf("signing_ca_ids = %v, want [k1]", caIDs)
	}
}
