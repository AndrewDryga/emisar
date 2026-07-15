package cloud

import (
	"testing"
	"time"
)

// sendRunActionUnsignedWithPackRef sends a run_action carrying a mismatched
// pack_ref and no attestation. The input is simultaneously
// rejectable by both the signature gate (unsigned) and the trust gate
// (bad hash), so the result reveals which gate fired first.
func sendRunActionUnsignedWithPackRef(t *testing.T, c *fakeConn, requestID, actionID string, args map[string]any, packRef string) {
	t.Helper()
	raw, err := marshalRunActionMsg(RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		ActionID: actionID, PackRef: packRef, Args: args, Reason: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	c.in <- raw
}

// Dispatch gate ORDERING: the signature gate runs before the trust
// (pack-hash) gate. An enforcing runner gets a request that is BOTH
// unsigned and carries a mismatched pack_ref. The result must be
// signature_invalid/signature_required — proving handleRun ran
// passesSignatureGate before passesTrustGate. If the trust gate had run
// first the result would instead be pack_hash_mismatch. The order matters:
// a bad signature says nothing about this runner's catalog, so it must not
// trigger the pack-mismatch re-advertise/pending-trust path.
func TestClient_GateOrder_SignatureBeforeTrust(t *testing.T) {
	conn, _, _ := runEnforcingClient(t)

	// Both gates would refuse this: no attestation (signature gate) AND a
	// hash that cannot match the on-disk pack (trust gate).
	sendRunActionUnsignedWithPackRef(t, conn, "req_order", "t.echo",
		map[string]any{"msg": "x"}, "sha256:DEFINITELY_NOT_THE_HASH")

	res := waitForResult(t, conn, "req_order", 3*time.Second)
	if res["status"] != "signature_invalid" {
		t.Fatalf("status=%v reason=%v error=%v — signature gate must fire before the trust gate",
			res["status"], res["reason"], res["error"])
	}
	if res["reason"] != "signature_required" {
		t.Fatalf("reason=%v, want signature_required (trust gate ran first if this is pack_hash_mismatch)", res["reason"])
	}
}

// Under outbox pressure the run RESULT is never dropped. enqueue
// (client.go:634-643) applies dropOldestProgress only to progress chunks;
// the terminal result uses the `never` policy (client.go:625-628), which
// appends past MaxPendingPerRun rather than evicting itself. So even when
// the per-run buffer is saturated with progress while the socket is down,
// the one message the cloud must eventually see — the result — survives,
// pushing out older progress instead.
func TestClient_Enqueue_ResultNeverDroppedUnderPressure(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	cli.opts.MaxPendingPerRun = 4

	s := &runState{requestID: "req_pressure"}

	// Fill the buffer to capacity, then keep pushing progress: each overflow
	// evicts the oldest progress chunk and bumps the dropped counter.
	for i := 0; i < cli.opts.MaxPendingPerRun*3; i++ {
		cli.enqueue(s, ActionProgressMsg{
			Envelope: Envelope{Type: MsgActionProgress, ProtocolVersion: ProtocolVersion, RequestID: "req_pressure"},
			Seq:      i,
			Stream:   "stdout",
			Chunk:    "chunk",
		}, dropOldestProgress)
	}

	// Now enqueue the terminal result with the never policy while the buffer
	// is already at/over capacity.
	result := ActionResultMsg{
		Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: "req_pressure"},
		Status:   "success",
	}
	cli.enqueue(s, result, never)

	s.mu.Lock()
	pending := append([]any(nil), s.pending...)
	dropped := s.dropped
	s.mu.Unlock()

	if dropped == 0 {
		t.Fatal("expected progress chunks to have been dropped under buffer pressure")
	}
	// The result must be present despite the buffer having been full.
	found := false
	for _, msg := range pending {
		if r, ok := msg.(ActionResultMsg); ok && r.Status == "success" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the result was dropped under buffer pressure (pending=%d, dropped=%d) — `never` policy must protect it",
			len(pending), dropped)
	}
	// The never-policy append exceeds the cap rather than evicting the result,
	// so it lands as the final queued message.
	if last, ok := pending[len(pending)-1].(ActionResultMsg); !ok || last.Status != "success" {
		t.Fatalf("the result must be the final queued message; last=%T", pending[len(pending)-1])
	}
}
