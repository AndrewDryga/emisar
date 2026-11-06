package cloud

import "testing"

func pendingProgress(t *testing.T, s *runState) []ActionProgressMsg {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()

	msgs := make([]ActionProgressMsg, 0, len(s.pending))
	for _, pending := range s.pending {
		progress, ok := pending.(ActionProgressMsg)
		if !ok {
			t.Fatalf("pending message %#v is not progress", pending)
		}
		msgs = append(msgs, progress)
	}
	return msgs
}

// The cloud writes per progress message it receives, so lines that pile up
// behind an undrained message ride out together. seq counts MESSAGES, because
// the cloud compares the run's reported ProgressChunks against the events it
// stored to decide whether output was omitted.
func TestClient_EnqueueProgress_MergesWhileQueued(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	s := &runState{requestID: "req_merge"}

	cli.enqueueProgress(s, s.requestID, "stdout", "one\n")
	cli.enqueueProgress(s, s.requestID, "stdout", "two\n")
	cli.enqueueProgress(s, s.requestID, "stderr", "err\n")
	cli.enqueueProgress(s, s.requestID, "stdout", "three\n")

	msgs := pendingProgress(t, s)
	if len(msgs) != 3 {
		t.Fatalf("queued %d messages, want 3 (two stdout lines merged)", len(msgs))
	}
	if msgs[0].Chunk != "one\ntwo\n" || msgs[0].Seq != 1 || msgs[0].Stream != "stdout" {
		t.Fatalf("first message = %#v, want the merged stdout pair at seq 1", msgs[0])
	}
	if msgs[1].Chunk != "err\n" || msgs[1].Seq != 2 {
		t.Fatalf("a stream change must start a new message, got %#v", msgs[1])
	}
	if msgs[2].Chunk != "three\n" || msgs[2].Seq != 3 {
		t.Fatalf("third message = %#v, want seq 3", msgs[2])
	}

	// ProgressChunks is read from this counter, so it has to equal the number
	// of messages the cloud will store — not the number of lines written.
	s.mu.Lock()
	reported := s.progressSeq
	s.mu.Unlock()
	if reported != len(msgs) {
		t.Fatalf("ProgressChunks would report %d for %d queued messages", reported, len(msgs))
	}
}

func TestClient_EnqueueProgress_StopsMergingAtTheSizeCap(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	s := &runState{requestID: "req_cap"}

	cli.enqueueProgress(s, s.requestID, "stdout", string(make([]byte, maxProgressChunkBytes-1)))
	cli.enqueueProgress(s, s.requestID, "stdout", "ab")

	msgs := pendingProgress(t, s)
	if len(msgs) != 2 {
		t.Fatalf("queued %d messages, want 2 — the cap must start a new one", len(msgs))
	}
	if len(msgs[0].Chunk) != maxProgressChunkBytes-1 || msgs[1].Chunk != "ab" {
		t.Fatal("the capped message was rewritten instead of starting a fresh one")
	}
}

// A requeued message was already handed to a failed Send: the cloud may hold it
// and deduplicates on (request_id, seq), so merging into it would change the
// bytes behind a seq it already has and the difference would be dropped.
func TestClient_EnqueueProgress_NeverMergesIntoAnAttemptedMessage(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	conn := &failAfterNConn{fakeConn: newFakeConn(), failAt: 1}

	s := &runState{requestID: "req_attempted"}
	cli.mu.Lock()
	cli.runs[s.requestID] = s
	cli.mu.Unlock()

	cli.enqueueProgress(s, s.requestID, "stdout", "sent\n")
	if err := cli.drainOnce(t.Context(), conn); err == nil {
		t.Fatal("drainOnce should surface the send failure")
	}

	cli.enqueueProgress(s, s.requestID, "stdout", "after\n")

	msgs := pendingProgress(t, s)
	if len(msgs) != 2 {
		t.Fatalf("queued %d messages, want 2 — the attempted one must stay untouched", len(msgs))
	}
	if msgs[0].Chunk != "sent\n" || msgs[0].Seq != 1 {
		t.Fatalf("the attempted message changed: %#v", msgs[0])
	}
	if msgs[1].Chunk != "after\n" || msgs[1].Seq != 2 {
		t.Fatalf("the new line must take its own seq, got %#v", msgs[1])
	}
}

// A reconnect prepends a recovery action_started for a run inside Engine.Run.
// That shifts the queue, so the attempted prefix must shift with it, or the
// next line merges into a seq the cloud already holds: the cloud keeps its
// first copy, drops the merged bytes, and progress_chunks still matches.
func TestClient_Reconnect_KeepsAttemptedProgressIntact(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	s := &runState{requestID: "req_reconnect", started: true}
	cli.mu.Lock()
	cli.runs[s.requestID] = s
	cli.mu.Unlock()

	cli.enqueueProgress(s, s.requestID, "stdout", "sent\n")
	// The Send fails after the cloud stored the frame.
	stored := map[int]string{1: "sent\n"}
	if err := cli.drainOnce(t.Context(), &failAfterNConn{fakeConn: newFakeConn(), failAt: 1}); err == nil {
		t.Fatal("drainOnce should surface the send failure")
	}
	if got := cli.requeueActiveStarts(); got != 1 {
		t.Fatalf("requeued %d action_started frames, want 1", got)
	}
	cli.enqueueProgress(s, s.requestID, "stdout", "after\n")

	next := newFakeConn()
	if err := cli.drainOnce(t.Context(), next); err != nil {
		t.Fatal(err)
	}
	next.mu.Lock()
	defer next.mu.Unlock()
	if len(next.sent) == 0 {
		t.Fatal("the new session sent nothing")
	}
	if _, ok := next.sent[0].(ActionStartedMsg); !ok {
		t.Fatalf("first frame = %T, want the recovery action_started", next.sent[0])
	}
	for _, msg := range next.sent[1:] {
		progress, ok := msg.(ActionProgressMsg)
		if !ok {
			t.Fatalf("unexpected frame %#v", msg)
		}
		if _, held := stored[progress.Seq]; !held {
			stored[progress.Seq] = progress.Chunk
		}
	}
	output := ""
	for seq := 1; seq <= len(stored); seq++ {
		output += stored[seq]
	}
	if output != "sent\nafter\n" || s.progressSeq != len(stored) {
		t.Fatalf("cloud kept %q in %d seqs (progress_chunks %d), want both lines", output, len(stored), s.progressSeq)
	}
}
