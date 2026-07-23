package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestPercentile(t *testing.T) {
	// 1..10 ms, nearest-rank.
	s := make([]time.Duration, 10)
	for i := range s {
		s[i] = time.Duration(i+1) * time.Millisecond
	}
	cases := []struct {
		p    int
		want time.Duration
	}{
		{50, 5 * time.Millisecond},
		{90, 9 * time.Millisecond},
		{95, 10 * time.Millisecond},
		{99, 10 * time.Millisecond},
		{100, 10 * time.Millisecond},
		{1, 1 * time.Millisecond},
	}
	for _, c := range cases {
		if got := percentile(s, c.p); got != c.want {
			t.Errorf("percentile(%d) = %s, want %s", c.p, got, c.want)
		}
	}
	if got := percentile(nil, 50); got != 0 {
		t.Errorf("percentile(empty) = %s, want 0", got)
	}
}

func TestSummarizeDropsWarmup(t *testing.T) {
	samples := []sample{
		{d: 1 * time.Millisecond, o: outOK, off: 0},                              // warmup — dropped
		{d: 99 * time.Millisecond, o: outTransport, off: 500 * time.Millisecond}, // warmup — dropped
		{d: 4 * time.Millisecond, o: outOK, off: 2 * time.Second},
		{d: 6 * time.Millisecond, o: outRateLimit, off: 3 * time.Second},
	}
	s := summarize(samples, time.Second, 5*time.Second)
	if s.measured != 2 {
		t.Fatalf("measured = %d, want 2 (warmup dropped)", s.measured)
	}
	if s.counts[outOK] != 1 || s.counts[outRateLimit] != 1 {
		t.Fatalf("counts = %v, want ok=1 rate_limited=1", s.counts)
	}
	if s.counts[outTransport] != 0 {
		t.Fatalf("warmup transport error leaked into counts: %v", s.counts)
	}
	if s.max != 6*time.Millisecond || s.min != 4*time.Millisecond {
		t.Fatalf("min/max = %s/%s, want 4ms/6ms", s.min, s.max)
	}
}

func TestHasRPCError(t *testing.T) {
	cases := []struct {
		body string
		want bool
	}{
		{`{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}`, false},
		{`{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"wrong key kind"}}`, true},
		{`{"jsonrpc":"2.0","id":1,"error":null}`, false},
		{``, false},
		{`not json`, false},
	}
	for _, c := range cases {
		if got := hasRPCError([]byte(c.body)); got != c.want {
			t.Errorf("hasRPCError(%q) = %v, want %v", c.body, got, c.want)
		}
	}
}

// TestRunAgainstStub exercises the whole closed-loop path end to end against a
// stub that mimics the portal's tools/list reply — proving the harness drives
// concurrent clients and produces a real profile without a live portal.
func TestRunAgainstStub(t *testing.T) {
	var hits int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&hits, 1)
		if r.URL.Path != "/api/mcp/rpc" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("missing bearer: %q", r.Header.Get("Authorization"))
		}
		if r.Header.Get("Mcp-Session-Id") == "" {
			t.Error("missing Mcp-Session-Id")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}`))
	}))
	defer srv.Close()

	cfg := config{
		url:      srv.URL,
		key:      "test-key",
		scenario: "tools_list",
		clients:  4,
		duration: 200 * time.Millisecond,
		warmup:   0,
		timeout:  5 * time.Second,
	}
	s, err := run(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if s.measured == 0 {
		t.Fatal("no samples recorded")
	}
	if s.counts[outOK] != s.measured {
		t.Fatalf("expected all ok, got %v", s.counts)
	}
	// The harness drops up to `clients` boundary requests (one per worker
	// in flight when the window closes), so the server may see slightly more
	// hits than the harness records — but never fewer.
	if got := int(atomic.LoadInt64(&hits)); got < s.measured || got > s.measured+cfg.clients {
		t.Fatalf("server saw %d hits, harness recorded %d (want within +%d)", got, s.measured, cfg.clients)
	}
}

func TestRunRateLimitClassified(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":"rate limited"}`))
	}))
	defer srv.Close()

	cfg := config{url: srv.URL, key: "k", scenario: "ping", clients: 2, duration: 100 * time.Millisecond, timeout: 2 * time.Second}
	s, err := run(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if s.counts[outRateLimit] == 0 || s.counts[outRateLimit] != s.measured {
		t.Fatalf("expected all rate_limited, got %v", s.counts)
	}
}
