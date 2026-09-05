package cloud

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
	"github.com/andrewdryga/emisar/runner/internal/outputschema"
)

type dedupBenchmarkProfile struct {
	name             string
	executedCommand  string
	structuredOutput json.RawMessage
}

type dedupBenchmarkInput struct {
	requestID string
	digest    string
	result    ActionResultMsg
}

// BenchmarkDedupRingDurableLifecycle measures real durable transitions with a
// fully persisted starting history. Counters measure bytes actually accepted
// by append and snapshot writes, not final file sizes (which double-count old
// bytes under append). Use -benchtime=3x for comparable short samples.
func BenchmarkDedupRingDurableLifecycle(b *testing.B) {
	profiles := dedupBenchmarkProfiles()
	cases := []struct {
		entries int
		profile dedupBenchmarkProfile
	}{
		{entries: 1, profile: profiles[0]},
		{entries: 128, profile: profiles[1]},
		{entries: 1024, profile: profiles[1]},
		{entries: 128, profile: profiles[2]},
		{entries: 1024, profile: profiles[2]},
	}

	for _, test := range cases {
		b.Run(fmt.Sprintf("entries=%d/%s", test.entries, test.profile.name), func(b *testing.B) {
			benchmarkDedupDurableLifecycle(b, test.entries, test.profile)
		})
	}
}

func BenchmarkDedupRingDurableLifecycleParallel(b *testing.B) {
	profile := dedupBenchmarkProfiles()[0]
	d := newBenchmarkDedupRing(b, 1024, profile)
	writes := countDedupBenchmarkWrites(d)
	inputs := make([]dedupBenchmarkInput, b.N)
	for i := range inputs {
		inputs[i] = newDedupBenchmarkInput(1024+i, profile)
	}

	var next atomic.Uint64
	var failure error
	var failureMu sync.Mutex
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(worker *testing.PB) {
		for worker.Next() {
			index := int(next.Add(1) - 1)
			if err := runDedupLifecycle(d, inputs[index]); err != nil {
				failureMu.Lock()
				if failure == nil {
					failure = err
				}
				failureMu.Unlock()
				return
			}
		}
	})
	b.StopTimer()
	if failure != nil {
		b.Fatal(failure)
	}
	reportDedupBenchmarkWrites(b, d, writes, b.N)
}

func benchmarkDedupDurableLifecycle(b *testing.B, entries int, profile dedupBenchmarkProfile) {
	d := newBenchmarkDedupRing(b, entries, profile)
	writes := countDedupBenchmarkWrites(d)
	inputs := make([]dedupBenchmarkInput, b.N)
	for i := range inputs {
		inputs[i] = newDedupBenchmarkInput(entries+i, profile)
	}

	var reserveElapsed time.Duration
	var completeElapsed time.Duration
	var acknowledgeElapsed time.Duration
	b.ReportAllocs()
	b.ResetTimer()
	for _, input := range inputs {
		started := time.Now()
		decision, _, err := d.reserve(input.requestID, input.digest)
		reserveElapsed += time.Since(started)
		if err != nil || decision != reservationNew {
			b.Fatalf("reserve %s: decision=%v err=%v", input.requestID, decision, err)
		}

		started = time.Now()
		if err := d.complete(input.requestID, input.digest, input.result); err != nil {
			b.Fatalf("complete %s: %v", input.requestID, err)
		}
		completeElapsed += time.Since(started)

		started = time.Now()
		if err := d.acknowledge(input.requestID); err != nil {
			b.Fatalf("acknowledge %s: %v", input.requestID, err)
		}
		acknowledgeElapsed += time.Since(started)
	}
	b.StopTimer()
	b.ReportMetric(float64(reserveElapsed.Nanoseconds())/float64(b.N), "reserve-ns/op")
	b.ReportMetric(float64(completeElapsed.Nanoseconds())/float64(b.N), "complete-ns/op")
	b.ReportMetric(float64(acknowledgeElapsed.Nanoseconds())/float64(b.N), "acknowledge-ns/op")
	reportDedupBenchmarkWrites(b, d, writes, b.N)
}

// A full capacity window crosses real compaction thresholds without changing
// counters to force a synthetic rollover. One benchmark operation is 1025
// lifecycles; lifecycle-ns and written-B/lifecycle are the amortized measures.
func BenchmarkDedupRingDurableCompactionWindow(b *testing.B) {
	const entries = 1024
	const window = entries + 1
	for _, profile := range dedupBenchmarkProfiles()[1:] {
		b.Run(profile.name, func(b *testing.B) {
			d := newBenchmarkDedupRing(b, entries, profile)
			writes := countDedupBenchmarkWrites(d)
			inputs := make([]dedupBenchmarkInput, b.N*window)
			for i := range inputs {
				inputs[i] = newDedupBenchmarkInput(entries+i, profile)
			}
			b.ReportAllocs()
			b.ResetTimer()
			started := time.Now()
			for _, input := range inputs {
				if err := runDedupLifecycle(d, input); err != nil {
					b.Fatal(err)
				}
			}
			elapsed := time.Since(started)
			b.StopTimer()
			if writes.snapshots.Load() == 0 {
				b.Fatal("benchmark window did not cross a compaction")
			}
			b.ReportMetric(float64(elapsed.Nanoseconds())/float64(len(inputs)), "lifecycle-ns")
			reportDedupBenchmarkWrites(b, d, writes, len(inputs))
		})
	}
}

func newBenchmarkDedupRing(b *testing.B, entries int, profile dedupBenchmarkProfile) *dedupRing {
	b.Helper()
	d := newDedupRing(entries, filepath.Join(b.TempDir(), dispatchLogFilename), "", nil)
	for i := 0; i < entries; i++ {
		input := newDedupBenchmarkInput(i, profile)
		d.keys = append(d.keys, input.requestID)
		d.records[input.requestID] = dedupEntry{
			RequestID:      input.requestID,
			DispatchSHA256: input.digest,
			State:          dispatchAcknowledged,
			Result:         input.result,
		}
	}
	if err := d.writeStore(); err != nil {
		b.Fatal(err)
	}
	return d
}

func newDedupBenchmarkInput(sequence int, profile dedupBenchmarkProfile) dedupBenchmarkInput {
	requestID := fmt.Sprintf("benchmark-request-%020d", sequence)
	return dedupBenchmarkInput{
		requestID: requestID,
		digest:    testDispatchDigest(requestID),
		result: testActionResult(requestID, ActionResultMsg{
			EventID:          "benchmark-event-" + requestID,
			ExecutedCommand:  profile.executedCommand,
			StructuredOutput: profile.structuredOutput,
		}),
	}
}

type dedupBenchmarkWrites struct {
	bytes     atomic.Int64
	snapshots atomic.Int64
}

type countingDispatchFile struct {
	dispatchFile
	bytes *atomic.Int64
}

func (f countingDispatchFile) Write(p []byte) (int, error) {
	n, err := f.dispatchFile.Write(p)
	f.bytes.Add(int64(n))
	return n, err
}

type countingDispatchWriter struct {
	io.Writer
	bytes *atomic.Int64
}

func (w countingDispatchWriter) Write(p []byte) (int, error) {
	n, err := w.Writer.Write(p)
	w.bytes.Add(int64(n))
	return n, err
}

func countDedupBenchmarkWrites(d *dedupRing) *dedupBenchmarkWrites {
	writes := &dedupBenchmarkWrites{}
	d.openAppend = func(path string) (dispatchFile, error) {
		f, err := openSecureLocalAppend(path)
		if err != nil {
			return nil, err
		}
		return countingDispatchFile{dispatchFile: f, bytes: &writes.bytes}, nil
	}
	d.replaceFile = func(path string, write func(io.Writer) error) error {
		writes.snapshots.Add(1)
		return fsutil.ReplaceFile(path, func(w io.Writer) error {
			return write(countingDispatchWriter{Writer: w, bytes: &writes.bytes})
		})
	}
	return writes
}

func reportDedupBenchmarkWrites(b *testing.B, d *dedupRing, writes *dedupBenchmarkWrites, lifecycles int) {
	b.Helper()
	b.SetBytes(writes.bytes.Load() / int64(b.N))
	b.ReportMetric(float64(dedupBenchmarkStoreSize(b, d.storePath)), "store-B")
	b.ReportMetric(float64(writes.bytes.Load())/float64(lifecycles), "written-B/lifecycle")
	b.ReportMetric(float64(writes.snapshots.Load()), "compactions")
}

func dedupBenchmarkStoreSize(b *testing.B, path string) int64 {
	b.Helper()
	info, err := os.Stat(path)
	if err != nil {
		b.Fatal(err)
	}
	return info.Size()
}

func runDedupLifecycle(d *dedupRing, input dedupBenchmarkInput) error {
	decision, _, err := d.reserve(input.requestID, input.digest)
	if err != nil {
		return fmt.Errorf("reserve %s: %w", input.requestID, err)
	}
	if decision != reservationNew {
		return fmt.Errorf("reserve %s: decision=%v", input.requestID, decision)
	}
	if err := d.complete(input.requestID, input.digest, input.result); err != nil {
		return fmt.Errorf("complete %s: %w", input.requestID, err)
	}
	if err := d.acknowledge(input.requestID); err != nil {
		return fmt.Errorf("acknowledge %s: %w", input.requestID, err)
	}
	return nil
}

func dedupBenchmarkProfiles() []dedupBenchmarkProfile {
	return []dedupBenchmarkProfile{
		{name: "minimal"},
		{
			name:             "representative",
			executedCommand:  strings.Repeat("x", 1<<10),
			structuredOutput: dedupBenchmarkJSONObject(2 << 10),
		},
		{
			name:             "contract_max",
			executedCommand:  strings.Repeat("x", maxExecutedCommandBytes),
			structuredOutput: dedupBenchmarkJSONObject(outputschema.MaxResultBytes),
		},
	}
}

func dedupBenchmarkJSONObject(size int) json.RawMessage {
	const prefix = `{"value":"`
	const suffix = `"}`
	return json.RawMessage(prefix + strings.Repeat("x", size-len(prefix)-len(suffix)) + suffix)
}
