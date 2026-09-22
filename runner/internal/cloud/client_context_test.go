package cloud

import (
	"context"
	"sync/atomic"
	"testing"
)

// Hide the standard context's private cancellation key so WithCancel uses the
// public AfterFunc contract. Count registrations retained by the daemon parent.
type trackedRunParent struct {
	context.Context
	children atomic.Int64
}

func (*trackedRunParent) Value(any) any { return nil }

func (p *trackedRunParent) AfterFunc(f func()) func() bool {
	p.children.Add(1)
	stop := context.AfterFunc(p.Context, f)
	return func() bool {
		if stop() {
			p.children.Add(-1)
			return true
		}
		return false
	}
}

func TestCompletedDispatchReleasesParentContext(t *testing.T) {
	for _, want := range []string{"success", "pack_hash_mismatch"} {
		t.Run(want, func(t *testing.T) {
			base, cancel := context.WithCancel(context.Background())
			defer cancel()
			parent := &trackedRunParent{Context: base}
			cli := buildClient(t, &queuedDialer{})
			hash := currentPackHash(t, cli, "t")
			if want == "pack_hash_mismatch" {
				hash = "wrong-pack-hash"
			}
			requestID := testRequestID(want)
			if err := cli.startRun(parent, RunActionMsg{
				Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: requestID},
				ActionID: "t.echo", ExpectedPackHash: hash, Args: map[string]any{"msg": "hello"}, Reason: "test",
			}); err != nil {
				t.Fatal(err)
			}
			cli.handlerWG.Wait()
			state := cli.runs[requestID]
			if state == nil || len(state.pending) == 0 {
				t.Fatal("dispatch did not produce a result")
			}
			result, ok := state.pending[len(state.pending)-1].(ActionResultMsg)
			if !ok || result.Status != want {
				t.Fatalf("dispatch status = %s, want %s", result.Status, want)
			}
			if got := parent.children.Load(); got != 0 {
				t.Errorf("completed dispatch retained %d parent cancellation registrations", got)
			}
			if parent.Err() != nil {
				t.Fatal("completed dispatch cancelled the daemon parent")
			}
		})
	}
}
