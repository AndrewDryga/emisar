package cloud

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestClient_EnqueueProgress_BoundsEveryEncodedMessage(t *testing.T) {
	for _, tc := range []struct {
		name  string
		chunk string
	}{
		{"long line", strings.Repeat("x", 300000)},
		{"JSON document", `{"value":"` + strings.Repeat("x", 300000) + `"}`},
		{"escaping", strings.Repeat("\x00\x01\"\\\n<>&", 30000)},
		{"multibyte boundaries", strings.Repeat("aé€😀\u2028", 30000)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
			s := &runState{requestID: "req_fragment"}
			cli.enqueueProgress(s, s.requestID, "stdout", tc.chunk)
			msgs := pendingProgress(t, s)
			if len(msgs) < 2 {
				t.Fatal("oversized output was not fragmented")
			}
			var reconstructed strings.Builder
			for i, msg := range msgs {
				encoded, err := json.Marshal(msg)
				if err != nil {
					t.Fatal(err)
				}
				if len(encoded) > 262144 || len(msg.Chunk) > maxProgressChunkBytes || !utf8.ValidString(msg.Chunk) {
					t.Fatalf("invalid fragment %d: encoded=%d raw=%d UTF-8=%t", i, len(encoded), len(msg.Chunk), utf8.ValidString(msg.Chunk))
				}
				var decoded ActionProgressMsg
				if err := json.Unmarshal(encoded, &decoded); err != nil {
					t.Fatal(err)
				}
				if decoded.Seq != i+1 || decoded.Stream != "stdout" || decoded.RequestID != s.requestID {
					t.Fatalf("fragment metadata changed: %#v", decoded)
				}
				reconstructed.WriteString(decoded.Chunk)
			}
			if reconstructed.String() != tc.chunk || s.progressSeq != len(msgs) || s.dropped != 0 {
				t.Fatal("fragmentation changed output or progress accounting")
			}
		})
	}
}

func TestClient_EnqueueProgress_FragmentDropsAreCounted(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}}, func(o *Options) {
		o.MaxPendingPerRun = 2
	})
	s := &runState{requestID: "req_fragment_drops"}
	cli.enqueueProgress(s, s.requestID, "stderr", strings.Repeat("x", maxProgressChunkBytes*5))
	msgs := pendingProgress(t, s)
	if len(msgs) != 2 || s.progressSeq != 5 || s.dropped != 3 || msgs[0].Seq != 4 || msgs[1].Seq != 5 {
		t.Fatalf("incorrect fragment drop accounting: queued=%d seq=%d dropped=%d", len(msgs), s.progressSeq, s.dropped)
	}
}

func TestClient_EnqueueProgress_FragmentReplayPreservesBytes(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	s := &runState{requestID: "req_fragment_replay"}
	cli.mu.Lock()
	cli.runs[s.requestID] = s
	cli.mu.Unlock()
	input := strings.Repeat("€", maxProgressChunkBytes)
	cli.enqueueProgress(s, s.requestID, "stdout", input)
	original := pendingProgress(t, s)
	conn := &failAfterNConn{fakeConn: newFakeConn(), failAt: 1}
	if err := cli.drainOnce(t.Context(), conn); err == nil {
		t.Fatal("send should fail")
	}
	cli.enqueueProgress(s, s.requestID, "stdout", "later")
	requeued := pendingProgress(t, s)
	for i, msg := range original {
		if requeued[i] != msg {
			t.Fatalf("replay changed fragment %d", i)
		}
	}
	if len(requeued) != len(original)+1 || requeued[len(original)].Chunk != "later" {
		t.Fatal("new output merged into an attempted fragment")
	}
}
