package cloud

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// This file closes the PHASE-3 "gap" rows on the dispatch-seam gates that live
// in internal/cloud — the pack-hash trust gate, the SIGHUP registry hot-swap as
// observed by a new dispatch, and admission precedence over a valid signature +
// matching pack hash. These sit at the dispatch wrapper (handleRun /
// passesTrustGate), not in the leaf packages, so the leaf-package suites
// correctly left them; the existing fake-cloud harness (client_test.go /
// gate_test.go / signature_test.go) reaches them with no production change.
//
// Harness reused here: newFakeConn, queuedDialer, buildClient, sendRunAction,
// sendRunActionWithPackContract, sendRunActionWithPackRef, waitForResult,
// waitUntil, enforcingClient, and attestationFor.

// --- Pack-hash trust gate ---------------------------------------------------

// A known pack-backed action must carry the hash the portal authorized. Missing
// the hash is a malformed dispatch and fails closed; PackRef is optional only
// because unsigned operator dispatches do not have a client attestation.
func TestClient_TrustGate_MissingExpectedHashRefuses(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	waitUntil(t, 2*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) >= 1 })
	sendRunActionWithPackContract(t, conn, "req_nopin", "t.echo", map[string]any{"msg": "ok"}, "", "")
	res := waitForResult(t, conn, "req_nopin", 3*time.Second)
	if res["status"] != "pack_hash_mismatch" {
		t.Fatalf("status=%v reason=%v error=%v, want pack_hash_mismatch",
			res["status"], res["reason"], res["error"])
	}
	if !strings.Contains(res["error"].(string), "<missing>") {
		t.Fatalf("error=%v, want missing-hash detail", res["error"])
	}
	requireResultEventID(t, res)
	waitUntil(t, 2*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) >= 2 })
}

// /
//
// When the cloud DOES pin a hash but the action id is unknown to this runner's
// registry, the trust gate has nothing to gate: passesTrustGate returns true on
// the `!ok || PackID == ""` branch (client.go:561-565) so the engine can produce
// its own unknown_action result, rather than the gate masking a missing action
// behind a pack-hash error. The pin is non-empty here precisely to drive the
// lookup branch (an empty pin would short-circuit earlier, T08).
func TestClient_TrustGate_UnknownActionSkipsGate(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// A pinned hash, but for an action the registry doesn't know. The gate must
	// defer to the engine's unknown_action rather than emit pack_hash_mismatch.
	sendRunActionWithPackRef(t, conn, cli, "req_unknown", "t.does_not_exist",
		map[string]any{"msg": "x"}, "t@0.0.1/sha256:SOME_PINNED_HASH")
	res := waitForResult(t, conn, "req_unknown", 3*time.Second)
	if res["status"] != "unknown_action" {
		t.Fatalf("status=%v reason=%v — an unknown action under a pinned hash must reach the engine's unknown_action, not the trust gate",
			res["status"], res["reason"])
	}
	if got := len(conn.sentByType(MsgRunnerState)); got != 1 {
		t.Fatalf("unknown-action path must not Readvertise; runner_state sends=%d, want 1", got)
	}
}

// A trust-gate refusal is terminal and idempotent: emitPackMismatch caches the
// pack_hash_mismatch result in the dedup ring (client.go:619), so a cloud retry
// of the SAME request_id replays the cached refusal via startRun's dedup path
// (client.go:301-306) WITHOUT re-running the gate — no second rehash, no second
// Readvertise. The runner must not re-do work (or re-broadcast) for a request it
// has already answered, even a refusal.
func TestClient_TrustGate_MismatchRefusalIsCachedForReplay(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Drain the initial connect state so the re-advertise count is unambiguous.
	waitUntil(t, 2*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) >= 1 })

	// First dispatch: mismatched pin → pack_hash_mismatch, refusal cached, and
	// exactly one re-advertise kicked.
	sendRunActionWithPackContract(t, conn, "req_cached", "t.echo", map[string]any{"msg": "x"}, "sha256:NOT_THE_HASH", "")
	res := waitForResult(t, conn, "req_cached", 3*time.Second)
	if res["status"] != "pack_hash_mismatch" {
		t.Fatalf("first dispatch status=%v, want pack_hash_mismatch", res["status"])
	}
	firstEventID := requireResultEventID(t, res)
	waitUntil(t, 2*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) >= 2 })

	// The refusal must be in the dedup ring — that's what makes the replay
	// skip the gate.
	if cached, ok := cli.dedup.lookup(testRequestID("req_cached")); !ok || cached.Status != "pack_hash_mismatch" {
		t.Fatalf("refusal not cached for replay: cached=%+v ok=%v", cached, ok)
	}

	stateAfterFirst := len(conn.sentByType(MsgRunnerState))

	// Second dispatch with the same request_id: the dedup path replays the
	// cached refusal. The gate does NOT run again, so no additional re-advertise.
	sendRunActionWithPackContract(t, conn, "req_cached", "t.echo", map[string]any{"msg": "x"}, "sha256:NOT_THE_HASH", "")

	// Wait until cloud has received the result a second time (two result copies
	// for the same request_id).
	waitUntil(t, 3*time.Second, func() bool {
		count := 0
		for _, m := range conn.sentByType(MsgActionResult) {
			if m["request_id"] == testRequestID("req_cached") {
				count++
			}
		}
		return count >= 2
	})
	for _, result := range conn.sentByType(MsgActionResult) {
		if result["request_id"] == testRequestID("req_cached") && result["event_id"] != firstEventID {
			t.Fatalf("replay event_id=%v, want cached %q", result["event_id"], firstEventID)
		}
	}

	// No further re-advertisement: the replay never re-entered passesTrustGate.
	// Give a brief grace for any (erroneous) extra state to land, then assert it
	// did not.
	if got := len(conn.sentByType(MsgRunnerState)); got != stateAfterFirst {
		t.Fatalf("replay re-ran the gate: runner_state count went %d -> %d (a cached refusal must not re-rehash or re-advertise)",
			stateAfterFirst, got)
	}
}

// --- Registry hot-swap (SIGHUP) observed by a new dispatch ------------------

// /
//
// A SIGHUP atomically swaps the engine's registry (engine.Reload stores a fresh
// *packs.Registry behind an atomic.Pointer). A NEW dispatch routed through the
// Client — dispatch → startRun → handleRun → passesTrustGate + engine.Run, both
// of which read c.opts.Engine.Registry() fresh per call — must observe the new
// pack set: an action that was unknown before the reload now executes after it.
// The engine-package tests cover the swap at the engine seam; this asserts it
// end-to-end through the cloud dispatch wrapper, which is where the trust gate
// and the engine each re-read the live registry on every run_action.
func TestClient_RegistrySwap_NewDispatchSeesReloadedPacks(t *testing.T) {
	conn := newFakeConn()
	cli, root := buildReloadableClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Before the reload, t.shout is unknown to the registry the dispatch reads.
	sendRunAction(t, conn, cli, "req_before_reload", "t.shout", map[string]any{"msg": "hi"})
	if res := waitForResult(t, conn, "req_before_reload", 3*time.Second); res["status"] != "unknown_action" {
		t.Fatalf("pre-reload t.shout status=%v, want unknown_action", res["status"])
	}

	// Operator installs a new action and SIGHUPs (Reload swaps the pointer).
	newAction := strings.Replace(echoActionYAML, "id: t.echo", "id: t.shout", 1)
	if err := os.WriteFile(filepath.Join(root, "p", "actions", "shout.yaml"), []byte(newAction), 0o644); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "p", "pack.yaml")
	manifest, _ := os.ReadFile(manifestPath)
	updated := strings.Replace(string(manifest),
		"  - actions/sleep.yaml\n",
		"  - actions/sleep.yaml\n  - actions/shout.yaml\n", 1)
	if updated == string(manifest) {
		t.Fatal("test manifest rewrite did not take effect")
	}
	if err := os.WriteFile(manifestPath, []byte(updated), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := cli.opts.Engine.Reload(); err != nil {
		t.Fatalf("reload: %v", err)
	}

	// A new dispatch after the swap must resolve and run the freshly added
	// action — proof the dispatch path observes the swapped registry.
	sendRunAction(t, conn, cli, "req_after_reload", "t.shout", map[string]any{"msg": "hi"})
	if res := waitForResult(t, conn, "req_after_reload", 3*time.Second); res["status"] != "success" {
		t.Fatalf("post-reload t.shout status=%v reason=%v — a new dispatch must see the reloaded pack set",
			res["status"], res["reason"])
	}
}

// --- Admission precedence over signature + trust ----------------------------

// Admission is the host operator's gate and runs unconditionally at the engine,
// BEFORE the registry lookup (engine.go:220-236) — and the engine runs only
// after handleRun's signature + trust gates have already passed. So a dispatch
// that is perfectly authenticated (valid signature from a trusted key) AND
// carries a matching pack hash is STILL refused when the host has denied the
// action id: the cloud cannot override a host admission deny. Reached through
// the engine/cloud composition — the same enforcing client the signature tests
// use, with the engine's local denylist set to block the action.
func TestClient_AdmissionDenyBeatsValidSignatureAndMatchingHash(t *testing.T) {
	conn := newFakeConn()
	cli, priv, _ := enforcingClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	// Host operator denies t.echo locally. Setting the engine's public Admission
	// field before Run starts is test wiring only — no production change; it is
	// the same field connect.go populates from config at boot.
	pol, err := admission.New(nil, []string{"t.echo"}, "")
	if err != nil {
		t.Fatal(err)
	}
	cli.opts.Engine.Admission = pol

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Build a dispatch the cloud could not be faulted for: a real signature from
	// the trusted key AND the runner's own matching pack hash. Both gates pass.
	args := map[string]any{"msg": "ok"}
	att := attestationFor(t, cli, priv, "t.echo", args)
	raw, err := marshalRunActionMsg(RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: testRequestID("req_admit_deny")},
		ActionID: "t.echo", ExpectedPackHash: currentPackHash(t, cli, "t"), PackRef: att.PackRef, Args: args,
		Reason: att.Reason, OperationID: att.OperationID, Attestation: att,
	})
	if err != nil {
		t.Fatal(err)
	}
	conn.in <- raw

	res := waitForResult(t, conn, "req_admit_deny", 3*time.Second)
	if res["status"] != "blocked_by_admission" {
		t.Fatalf("status=%v reason=%v — a host admission deny must win over a valid signature + matching pack hash",
			res["status"], res["reason"])
	}
}

// --- test-only builder (no production change) -------------------------------

// buildReloadableClient is buildClient with the pack root surfaced and wired
// into the engine's PackDirs so engine.Reload() (the SIGHUP path) can re-read
// the same dir the test mutates. buildClient hides its TempDir root and leaves
// PackDirs empty, which a Reload test needs; this is the one piece that builder
// doesn't expose, so it is reconstructed here against the same loaders/sinks.
func buildReloadableClient(t *testing.T, dialer Dialer) (*Client, string) {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(`schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
  - actions/sleep.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoActionYAML), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "sleep.yaml"), []byte(longActionYAML), 0o644))

	dirs := []string{root}
	reg, err := packs.LoadAll(dirs, packs.LoadOptions{})
	must(err)
	sink, err := audit.OpenJSONL(filepath.Join(root, "events.jsonl"), audit.JSONLOptions{})
	must(err)
	j := audit.New(audit.Defaults{}, sink)
	t.Cleanup(func() { _ = j.Close() })
	eng := engine.New(engine.Config{
		Registry: reg, Executor: executor.New(), Journal: j, Redactor: redact.Empty(),
		PreviewBytes: 256, PackDirs: dirs,
	})
	cli := NewClient(dialer, Options{
		StateBuilder: &StateBuilder{
			Version:     "0.2.0",
			GetRegistry: eng.Registry,
		},
		Engine:            eng,
		HeartbeatEvery:    time.Hour,
		ReconnectMin:      10 * time.Millisecond,
		ReconnectMax:      20 * time.Millisecond,
		MaxConcurrentRuns: 4,
		MaxPendingPerRun:  2048,
	})
	return cli, root
}
