package audit

import (
	"context"
	"sync"
	"time"
)

// Sink is the durable destination for journal events.
type Sink interface {
	Write(ctx context.Context, ev Event) error
	Close() error
}

// Defaults stamp runner-level fields onto every event if not otherwise
// supplied by the caller.
type Defaults struct {
	AgentID string
	Group   string
}

type Journal struct {
	mu       sync.Mutex
	sink     Sink
	defaults Defaults
}

// New returns a Journal that writes to sink.
func New(defaults Defaults, sink Sink) *Journal {
	return &Journal{sink: sink, defaults: defaults}
}

// SetAgentID updates the runner identity stamped onto subsequent events.
// Execution surfaces call this after resolving the installation's durable ID.
func (j *Journal) SetAgentID(id string) {
	j.mu.Lock()
	j.defaults.AgentID = id
	j.mu.Unlock()
}

// Record stamps default fields, assigns an EventID if empty, and writes the
// event to the durable sink.
func (j *Journal) Record(ctx context.Context, ev Event) (Event, error) {
	j.mu.Lock()
	defer j.mu.Unlock()

	if ev.EventID == "" {
		ev.EventID = NewID("evt")
	}
	if ev.Time.IsZero() {
		ev.Time = time.Now().UTC()
	} else {
		ev.Time = ev.Time.UTC()
	}
	if ev.Group == "" {
		ev.Group = j.defaults.Group
	}
	if ev.AgentID == "" {
		ev.AgentID = j.defaults.AgentID
	}

	if err := j.sink.Write(ctx, ev); err != nil {
		return ev, err
	}
	return ev, nil
}

// Close closes the durable sink.
func (j *Journal) Close() error {
	return j.sink.Close()
}
