package main

import (
	"encoding/json"
	"os"
	"testing"
)

// `emisar state` builds the runner_state advertisement from config + the
// loaded registry + admission and prints it as JSON. This drives the real
// command (boot → StateBuilder → printJSON) against a temp config + a
// one-action pack and asserts the advertised shape: identity from config,
// the loaded pack and its action present. closes RUN-029-T01.
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
// identity-only catalog, not an error. closes RUN-029-T03.
func TestStateCmd_EmptyRegistryIdentityOnly(t *testing.T) {
	// closes RUN-029-T03
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
	// Identity is still advertised.
	if st["type"] != "runner_state" || st["group"] != "test" {
		t.Fatalf("identity should still be present: type=%v group=%v", st["type"], st["group"])
	}
	// No actions, and no non-empty packs map (omitempty may drop it entirely).
	if actions, _ := st["actions"].([]any); len(actions) != 0 {
		t.Fatalf("empty registry must advertise zero actions, got %d:\n%s", len(actions), out)
	}
	if pk, ok := st["packs"].(map[string]any); ok && len(pk) != 0 {
		t.Fatalf("empty registry must advertise no packs, got %v:\n%s", pk, out)
	}
}

// The documented divergence (Gaps #1): `state` advertises runner_id from
// cfg.Runner.ID directly (NOT the resolved/minted external id that `connect`
// uses) and never wires GetVerifier, so even with enforcing signing in config
// the printed state OMITS the enforcement fields. This pins that `state` is a
// config-only preview, not a faithful mirror of what `connect` sends.
// closes RUN-029-T04.
func TestStateCmd_DivergesConfigOnlyIDNoVerifier(t *testing.T) {
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
	// The minimal config sets no runner.id, so state advertises the empty
	// config value rather than minting/resolving one like connect does.
	if st["runner_id"] != "" {
		t.Fatalf("runner_id = %v, want \"\" (state uses cfg.Runner.ID, unset here)", st["runner_id"])
	}
	// state never wires GetVerifier, so enforcement fields are omitted entirely
	// (omitempty) even if signing were configured.
	if _, present := st["enforce_signatures"]; present {
		t.Fatalf("state must not advertise enforce_signatures (no verifier wired):\n%s", out)
	}
	if _, present := st["signing_key_ids"]; present {
		t.Fatalf("state must not advertise signing_key_ids (no verifier wired):\n%s", out)
	}
}
