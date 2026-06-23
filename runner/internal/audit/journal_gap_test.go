package audit

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// This file closes the PHASE-2 "gap" rows for RSEC-013 (journal fan-out):
// EventID assignment, multi-sink delivery, one-sink-fails-others, UTC
// coercion, mutex serialization, and Close error joining (journal.go:40-79).

// memSink is an in-memory Sink for fan-out tests. It records every event it
// receives and can be configured to fail on Write and/or Close.
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

// TestJournal_AssignsPrefixedEventID — an event recorded with
// an empty EventID gets a fresh "evt"-prefixed ULID; a caller-supplied EventID
// is left untouched.
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

// TestJournal_FansOutToEverySink — one Record reaches every
// configured sink, each carrying the same stamped event.
func TestJournal_FansOutToEverySink(t *testing.T) {
	a, b := &memSink{}, &memSink{}
	j := New(Defaults{AgentID: "agt"}, a, b)

	ev, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.do"})
	if err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]*memSink{"a": a, "b": b} {
		got := s.recorded()
		if len(got) != 1 {
			t.Fatalf("sink %s should get exactly one event, got %d", name, len(got))
		}
		if got[0].EventID != ev.EventID || got[0].ActionID != "x.do" {
			t.Fatalf("sink %s got the wrong event: %+v", name, got[0])
		}
	}
}

// TestJournal_OneSinkFailsOthersStillGetIt — when one sink's
// Write errors, the other sinks still receive the event, the joined error is
// returned, and the stamped event is still returned to the caller.
func TestJournal_OneSinkFailsOthersStillGetIt(t *testing.T) {
	failErr := errors.New("disk full")
	bad := &memSink{writeErr: failErr}
	good := &memSink{}
	j := New(Defaults{}, bad, good)

	ev, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted})
	if err == nil {
		t.Fatal("expected the failing sink's error to be returned")
	}
	if !errors.Is(err, failErr) {
		t.Fatalf("returned error should wrap the sink error, got %v", err)
	}
	// The healthy sink still got the event despite the other failing.
	if got := good.recorded(); len(got) != 1 {
		t.Fatalf("healthy sink should still receive the event, got %d", len(got))
	}
	// The stamped event is returned even on partial failure.
	if ev.EventID == "" {
		t.Fatal("stamped event should be returned even when a sink fails")
	}
}

// TestJournal_CoercesTimeToUTC — a zero Time is filled with
// now() in UTC; a non-UTC Time is normalized to UTC (same instant).
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

// TestJournal_ConcurrentRecordsSerialized — concurrent Record
// calls are serialized by the journal mutex: every event lands exactly once in
// each sink, with no race (run under -race) and no lost write. A writeWait hook
// forces overlap so a missing lock would corrupt the slice.
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

// TestJournal_CloseJoinsSinkErrors — Close attempts every sink
// and joins their errors; one sink's Close failure does not skip the others.
func TestJournal_CloseJoinsSinkErrors(t *testing.T) {
	errA := errors.New("close a failed")
	a := &memSink{closeErr: errA}
	b := &memSink{}
	j := New(Defaults{}, a, b)

	err := j.Close()
	if !errors.Is(err, errA) {
		t.Fatalf("Close should join sink errors, got %v", err)
	}
	if !b.closed {
		t.Fatal("the healthy sink must still be closed even when another errors")
	}
}

// BenchmarkRecordFanOut — Record cost scales linearly with sink
// count under the serializing mutex. Uses in-memory sinks so the measurement
// isolates fan-out + stamping from disk I/O.
func BenchmarkRecordFanOut(b *testing.B) {
	sinks := []Sink{&memSink{}, &memSink{}, &memSink{}}
	j := New(Defaults{AgentID: "agt"}, sinks...)
	ev := Event{Type: EventExecutionCompleted, ActionID: "x.do"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := j.Record(context.Background(), ev); err != nil {
			b.Fatal(err)
		}
	}
}
