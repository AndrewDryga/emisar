package audit

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Sink is a destination for journal events. JSONL is the default sink; a
// future cloud sink can be added by satisfying this interface.
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

// Journal fans events out to one or more sinks. Sink failures are joined
// into the returned error but do not stop other sinks from being attempted.
type Journal struct {
	mu       sync.Mutex
	sinks    []Sink
	defaults Defaults
}

// New returns a Journal that writes to all given sinks.
func New(defaults Defaults, sinks ...Sink) *Journal {
	return &Journal{sinks: sinks, defaults: defaults}
}

// SetAgentID updates the runner identity stamped onto subsequent events.
// Execution surfaces call this after resolving the installation's durable ID.
func (j *Journal) SetAgentID(id string) {
	j.mu.Lock()
	j.defaults.AgentID = id
	j.mu.Unlock()
}

// Record writes the event to every configured sink, stamping default
// fields and assigning an EventID if empty.
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

	var errs []error
	for _, s := range j.sinks {
		if err := s.Write(ctx, ev); err != nil {
			errs = append(errs, fmt.Errorf("%T: %w", s, err))
		}
	}
	if len(errs) > 0 {
		return ev, errors.Join(errs...)
	}
	return ev, nil
}

// Close closes all sinks.
func (j *Journal) Close() error {
	var errs []error
	for _, s := range j.sinks {
		if err := s.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
