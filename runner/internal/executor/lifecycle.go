package executor

import (
	"context"
	"sync"
	"syscall"
	"time"
)

// processLifecycle serializes process-group signals with completion so a
// delayed hard-kill cannot target a recycled process-group id.
type processLifecycle struct {
	mu   sync.Mutex
	pid  int
	done bool
}

func (p *processLifecycle) signal(sig syscall.Signal) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.done {
		return
	}
	_ = killGroup(p.pid, sig)
}

func (p *processLifecycle) finish() {
	p.mu.Lock()
	p.done = true
	p.mu.Unlock()
}

func (p *processLifecycle) watch(ctx context.Context, grace time.Duration, finished <-chan struct{}) {
	select {
	case <-ctx.Done():
		p.signal(syscall.SIGTERM)
	case <-finished:
		return
	}

	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-timer.C:
		p.signal(syscall.SIGKILL)
	case <-finished:
	}
}
