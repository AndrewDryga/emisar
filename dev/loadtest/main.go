// Command loadtest drives the emisar MCP JSON-RPC surface
// (POST /api/mcp/rpc) with a fixed pool of concurrent virtual clients and
// reports a latency/error profile: throughput, p50/p90/p95/p99/max, and a
// breakdown of outcomes (ok / rate-limited / http-error / rpc-error /
// transport-error).
//
// It is CLOSED-LOOP: `-clients N` goroutines each fire the next request the
// instant the previous one returns, so offered concurrency equals N and
// throughput is bounded by response latency. That is exactly the probe you
// want for a concurrency ceiling — push N up until latency inflects or errors
// appear, and the knee is the limit. Each virtual client carries a distinct
// Mcp-Session-Id, mirroring N independent bridge processes / MCP-over-HTTP
// clients hitting one key.
//
// Stdlib only, on purpose (dev tool, zero supply-chain surface). See README.md
// for the full test plan, the runner-connection scenario, and the code-derived
// design limits this exercises.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

// The docker-compose stack seeds this fixed MCP key (kind :mcp) so the harness
// works against `docker compose up` with no manual key minting. It is a
// well-known DEV secret — never a real deployment.
const devMCPKey = "emk-mcp-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD"

// maxResponseBytes caps the buffered response per request. The stats only need
// the status + whether the JSON-RPC body carried an error, so a small cap keeps
// a huge tools/list catalog from dominating memory under high concurrency.
const maxResponseBytes = 4 << 20

type config struct {
	url      string
	key      string
	scenario string
	clients  int
	duration time.Duration
	warmup   time.Duration
	timeout  time.Duration
}

// outcome classifies one completed request. Every request contributes a latency
// sample regardless of outcome — an error still took time, and hiding its
// latency would flatter the profile.
type outcome int

const (
	outOK        outcome = iota // HTTP 2xx and no top-level JSON-RPC "error"
	outRateLimit                // HTTP 429 — past the 300/min-per-bearer cap
	outHTTPError                // other non-2xx (401/400/5xx …)
	outRPCError                 // HTTP 2xx but the JSON-RPC body carried "error"
	outTransport                // client.Do / body-read failure (never reached the app)
)

var outcomeNames = map[outcome]string{
	outOK:        "ok",
	outRateLimit: "rate_limited",
	outHTTPError: "http_error",
	outRPCError:  "rpc_error",
	outTransport: "transport_error",
}

// sample is one completed request: its latency, its outcome, and its completion
// offset from the run start (so warmup requests can be dropped from the stats).
type sample struct {
	d   time.Duration
	o   outcome
	off time.Duration
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.url, "url", "http://localhost:4010", "portal base URL (docker-compose publishes 4010)")
	flag.StringVar(&cfg.key, "key", devMCPKey, "MCP API key (emk-...); default is the docker-compose dev key")
	flag.StringVar(&cfg.scenario, "scenario", "tools_list", "request per iteration: tools_list | ping | initialize")
	flag.IntVar(&cfg.clients, "clients", 16, "concurrent virtual MCP clients (offered concurrency)")
	flag.DurationVar(&cfg.duration, "duration", 15*time.Second, "measured window")
	flag.DurationVar(&cfg.warmup, "warmup", 2*time.Second, "warmup window excluded from stats")
	flag.DurationVar(&cfg.timeout, "timeout", 30*time.Second, "per-request timeout")
	flag.Parse()

	if _, ok := buildRequestBody(cfg.scenario, 1); !ok {
		fmt.Fprintf(os.Stderr, "unknown -scenario %q (want tools_list | ping | initialize)\n", cfg.scenario)
		os.Exit(2)
	}
	if cfg.clients < 1 {
		fmt.Fprintln(os.Stderr, "-clients must be >= 1")
		os.Exit(2)
	}

	sum, err := run(context.Background(), cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loadtest:", err)
		os.Exit(1)
	}
	printReport(os.Stdout, cfg, sum)
}

// run fires the closed-loop workload and returns the aggregated summary. It is
// the testable core: point it at an httptest stub to verify the harness end to
// end without a live portal.
func run(ctx context.Context, cfg config) (summary, error) {
	client := &http.Client{
		Timeout: cfg.timeout,
		// The default Transport keeps only 2 idle conns per host, which would
		// serialize keep-alive reuse and understate real concurrency. Size the
		// idle pool to the client count so N workers genuinely run in parallel.
		Transport: &http.Transport{
			MaxIdleConns:        cfg.clients * 2,
			MaxIdleConnsPerHost: cfg.clients * 2,
			IdleConnTimeout:     90 * time.Second,
		},
	}
	defer client.CloseIdleConnections()

	total := cfg.warmup + cfg.duration
	runCtx, cancel := context.WithTimeout(ctx, total)
	defer cancel()

	start := time.Now()
	var wg sync.WaitGroup
	perWorker := make([][]sample, cfg.clients)
	for i := 0; i < cfg.clients; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			perWorker[id] = worker(runCtx, client, cfg, start, sessionID())
		}(i)
	}
	wg.Wait()

	var all []sample
	for _, s := range perWorker {
		all = append(all, s...)
	}
	return summarize(all, cfg.warmup, cfg.duration), nil
}

// worker fires requests back-to-back until the context deadline, recording one
// sample per completed request. Each worker owns a distinct session id and its
// own JSON-RPC id counter, so it looks like one independent MCP client.
func worker(ctx context.Context, client *http.Client, cfg config, start time.Time, sess string) []sample {
	var out []sample
	reqID := 0
	for ctx.Err() == nil {
		reqID++
		body, _ := buildRequestBody(cfg.scenario, reqID)
		t0 := time.Now()
		o := doOnce(ctx, client, cfg, sess, body)
		// The window closed mid-request: the run's own deadline aborted this
		// call, so it's an artifact of shutdown, not a real outcome — drop it.
		if ctx.Err() != nil {
			break
		}
		out = append(out, sample{d: time.Since(t0), o: o, off: t0.Sub(start)})
	}
	return out
}

// doOnce performs one request and classifies the outcome. A context-cancelled
// error at the deadline boundary is not counted — that request never really ran.
func doOnce(ctx context.Context, client *http.Client, cfg config, sess string, body []byte) outcome {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.url+"/api/mcp/rpc", bytes.NewReader(body))
	if err != nil {
		return outTransport
	}
	req.Header.Set("Authorization", "Bearer "+cfg.key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Mcp-Session-Id", sess)

	resp, err := client.Do(req)
	if err != nil {
		return outTransport
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return outTransport
	}

	switch {
	case resp.StatusCode == http.StatusTooManyRequests:
		return outRateLimit
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return outHTTPError
	case hasRPCError(raw):
		return outRPCError
	default:
		return outOK
	}
}

// hasRPCError reports whether a JSON-RPC response carries a top-level "error".
// A 200 with an "error" member is an application failure (wrong key kind,
// method not found, …), not a healthy response — count it apart from ok.
func hasRPCError(body []byte) bool {
	var env struct {
		Error json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return false // 202 empty body or non-JSON; not an rpc-level error
	}
	return len(bytes.TrimSpace(env.Error)) > 0 && !bytes.Equal(bytes.TrimSpace(env.Error), []byte("null"))
}

// buildRequestBody returns the JSON-RPC frame for a scenario, and ok=false for
// an unknown scenario. Frames are verified against the portal controller:
// initialize/ping need no mcp-key; tools_list requires kind==:mcp.
func buildRequestBody(scenario string, id int) ([]byte, bool) {
	switch scenario {
	case "tools_list":
		return frame(id, "tools/list", nil), true
	case "ping":
		return frame(id, "ping", nil), true
	case "initialize":
		return frame(id, "initialize", map[string]any{
			"protocolVersion": "2025-06-18",
			"clientInfo":      map[string]any{"name": "emisar-loadtest", "version": "dev"},
		}), true
	default:
		return nil, false
	}
}

func frame(id int, method string, params any) []byte {
	m := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		m["params"] = params
	}
	b, _ := json.Marshal(m)
	return b
}

func sessionID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// summary is the aggregated profile over the measured (post-warmup) window.
type summary struct {
	counts   map[outcome]int
	total    int
	window   time.Duration
	p50      time.Duration
	p90      time.Duration
	p95      time.Duration
	p99      time.Duration
	min      time.Duration
	max      time.Duration
	mean     time.Duration
	measured int // samples kept (post-warmup)
}

// summarize keeps only post-warmup samples, then computes the latency
// percentiles and per-outcome counts. window is the measured duration used for
// the throughput figure in the report.
func summarize(samples []sample, warmup, window time.Duration) summary {
	s := summary{counts: map[outcome]int{}, window: window}
	var lat []time.Duration
	var sum time.Duration
	for _, x := range samples {
		if x.off < warmup {
			continue // warmup request — excluded from the profile
		}
		s.total++
		s.counts[x.o]++
		lat = append(lat, x.d)
		sum += x.d
	}
	s.measured = len(lat)
	if s.measured == 0 {
		return s
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	s.min = lat[0]
	s.max = lat[len(lat)-1]
	s.mean = sum / time.Duration(s.measured)
	s.p50 = percentile(lat, 50)
	s.p90 = percentile(lat, 90)
	s.p95 = percentile(lat, 95)
	s.p99 = percentile(lat, 99)
	return s
}

// percentile returns the nearest-rank pth percentile of a sorted slice.
func percentile(sorted []time.Duration, p int) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	rank := (p*len(sorted) + 99) / 100 // ceil(p/100 * n)
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}

func printReport(w io.Writer, cfg config, s summary) {
	fmt.Fprintf(w, "emisar MCP load — %s\n", cfg.url)
	fmt.Fprintf(w, "  scenario=%s clients=%d duration=%s (warmup %s excluded)\n",
		cfg.scenario, cfg.clients, cfg.duration, cfg.warmup)
	fmt.Fprintf(w, "  measured requests: %d\n", s.measured)
	if s.measured == 0 {
		fmt.Fprintln(w, "  (no post-warmup samples — raise -duration or lower -warmup)")
		return
	}
	rps := float64(s.measured) / s.window.Seconds()
	fmt.Fprintf(w, "  throughput: %.1f req/s\n", rps)
	fmt.Fprintf(w, "  latency: p50=%s p90=%s p95=%s p99=%s min=%s max=%s mean=%s\n",
		rnd(s.p50), rnd(s.p90), rnd(s.p95), rnd(s.p99), rnd(s.min), rnd(s.max), rnd(s.mean))
	fmt.Fprint(w, "  outcomes:")
	for _, o := range []outcome{outOK, outRateLimit, outHTTPError, outRPCError, outTransport} {
		if n := s.counts[o]; n > 0 {
			fmt.Fprintf(w, " %s=%d", outcomeNames[o], n)
		}
	}
	fmt.Fprintln(w)
	if s.counts[outRateLimit] > 0 {
		fmt.Fprintln(w, "  note: 429s seen — you hit the 300/min-per-bearer MCP cap; use more keys or a longer window.")
	}
}

// rnd trims sub-microsecond noise so the report reads cleanly.
func rnd(d time.Duration) time.Duration { return d.Round(time.Microsecond) }
