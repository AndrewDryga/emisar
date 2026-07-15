package audit

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// memSink is an in-memory Sink for journal tests. It records every event it
// receives and can be configured to fail on Write or Close.
type memSink struct {
	mu        sync.Mutex
	events    []Event
	writeErr  error
	closeErr  error
	closed    bool
	writeWait func() // optional hook to interleave goroutines
}

func (m *memSink) Write(_ context.Context, ev Event) error {
	if m.writeWait != nil {
		m.writeWait()
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.writeErr != nil {
		return m.writeErr
	}
	m.events = append(m.events, ev)
	return nil
}

func (m *memSink) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	return m.closeErr
}

func (m *memSink) recorded() []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Event(nil), m.events...)
}

func TestJournal_AssignsPrefixedEventID(t *testing.T) {
	sink := &memSink{}
	j := New(Defaults{}, sink)

	ev, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(ev.EventID, "evt_") {
		t.Fatalf("empty EventID should get an evt_-prefixed ULID, got %q", ev.EventID)
	}
	// The same ID must be what reached the sink.
	if got := sink.recorded(); len(got) != 1 || got[0].EventID != ev.EventID {
		t.Fatalf("sink should receive the stamped EventID %q, got %+v", ev.EventID, got)
	}

	// A supplied EventID is preserved.
	ev2, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, EventID: "evt_caller"})
	if err != nil {
		t.Fatal(err)
	}
	if ev2.EventID != "evt_caller" {
		t.Fatalf("caller EventID must be preserved, got %q", ev2.EventID)
	}
}

func TestJournal_SetAgentIDUpdatesSubsequentEvents(t *testing.T) {
	sink := &memSink{}
	j := New(Defaults{AgentID: "config-only"}, sink)
	j.SetAgentID("durable-runner-id")

	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted}); err != nil {
		t.Fatal(err)
	}
	got := sink.recorded()
	if len(got) != 1 || got[0].AgentID != "durable-runner-id" {
		t.Fatalf("recorded events = %+v, want durable runner id", got)
	}
}

func TestJournal_ReturnsSinkWriteError(t *testing.T) {
	writeErr := errors.New("disk full")
	j := New(Defaults{}, &memSink{writeErr: writeErr})

	ev, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted})
	if err == nil {
		t.Fatal("expected sink error")
	}
	if !errors.Is(err, writeErr) {
		t.Fatalf("Record error = %v, want %v", err, writeErr)
	}
	if ev.EventID == "" {
		t.Fatal("Record should return the stamped event on write failure")
	}
}

func TestJournal_CoercesTimeToUTC(t *testing.T) {
	sink := &memSink{}
	j := New(Defaults{}, sink)

	// Zero time → set to now, in UTC.
	zero, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted})
	if err != nil {
		t.Fatal(err)
	}
	if zero.Time.IsZero() {
		t.Fatal("zero Time should be filled in")
	}
	if zero.Time.Location() != time.UTC {
		t.Fatalf("filled Time should be UTC, got %v", zero.Time.Location())
	}

	// Non-UTC time → normalized to UTC, same instant.
	plus5 := time.FixedZone("UTC+5", 5*3600)
	instant := time.Date(2026, 6, 21, 10, 0, 0, 0, plus5)
	set, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, Time: instant})
	if err != nil {
		t.Fatal(err)
	}
	if set.Time.Location() != time.UTC {
		t.Fatalf("set Time should be coerced to UTC, got %v", set.Time.Location())
	}
	if !set.Time.Equal(instant) {
		t.Fatalf("coercion must preserve the instant: got %v, want %v", set.Time, instant)
	}
}

func TestJournal_ConcurrentRecordsSerialized(t *testing.T) {
	const n = 50
	gate := make(chan struct{})
	sink := &memSink{writeWait: func() { <-gate }}
	j := New(Defaults{}, sink)

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted}); err != nil {
				t.Errorf("record: %v", err)
			}
		}()
	}
	// Release all writers; the journal mutex must still serialize them so the
	// sink's append is never concurrent.
	close(gate)
	wg.Wait()

	if got := len(sink.recorded()); got != n {
		t.Fatalf("expected %d events recorded exactly once, got %d", n, got)
	}
	// Every assigned EventID must be unique — proves no two Records raced into
	// the same stamping.
	seen := make(map[string]bool, n)
	for _, ev := range sink.recorded() {
		if seen[ev.EventID] {
			t.Fatalf("duplicate EventID %q — records were not serialized", ev.EventID)
		}
		seen[ev.EventID] = true
	}
}

func TestJournal_ReturnsSinkCloseError(t *testing.T) {
	closeErr := errors.New("close failed")
	sink := &memSink{closeErr: closeErr}
	j := New(Defaults{}, sink)

	err := j.Close()
	if !errors.Is(err, closeErr) {
		t.Fatalf("Close error = %v, want %v", err, closeErr)
	}
	if !sink.closed {
		t.Fatal("Close did not close sink")
	}
}

func BenchmarkJournalRecord(b *testing.B) {
	j := New(Defaults{AgentID: "agt"}, &memSink{})
	ev := Event{Type: EventExecutionCompleted, ActionID: "x.do"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := j.Record(context.Background(), ev); err != nil {
			b.Fatal(err)
		}
	}
}
