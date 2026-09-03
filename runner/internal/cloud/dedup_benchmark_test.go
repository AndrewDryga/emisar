package cloud

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

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

// BenchmarkDedupRingDurableLifecycle measures the real append-and-sync path at
// each retained-ring size. Use a fixed benchtime (for example, -benchtime=3x)
// for repeatable paired samples.
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
	storeBytes, appendedBytes := measureDedupLifecycleBytes(
		b,
		d,
		newDedupBenchmarkInput(1024, profile),
	)
	inputs := make([]dedupBenchmarkInput, b.N)
	for i := range inputs {
		inputs[i] = newDedupBenchmarkInput(1025+i, profile)
	}

	var next atomic.Uint64
	var failure error
	var failureMu sync.Mutex
	b.ReportAllocs()
	b.SetBytes(appendedBytes)
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
	b.ReportMetric(float64(storeBytes), "store-B")
	b.ReportMetric(float64(appendedBytes), "appended-B/lifecycle")
}

func benchmarkDedupDurableLifecycle(b *testing.B, entries int, profile dedupBenchmarkProfile) {
	d := newBenchmarkDedupRing(b, entries, profile)
	storeBytes, appendedBytes := measureDedupLifecycleBytes(
		b,
		d,
		newDedupBenchmarkInput(entries, profile),
	)
	inputs := make([]dedupBenchmarkInput, b.N)
	for i := range inputs {
		inputs[i] = newDedupBenchmarkInput(entries+1+i, profile)
	}

	var reserveElapsed time.Duration
	var completeElapsed time.Duration
	var acknowledgeElapsed time.Duration
	b.ReportAllocs()
	b.SetBytes(appendedBytes)
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
	b.ReportMetric(float64(storeBytes), "store-B")
	b.ReportMetric(float64(appendedBytes), "appended-B/lifecycle")
}

func BenchmarkDedupRingCompaction(b *testing.B) {
	profile := dedupBenchmarkProfiles()[2]
	d := newBenchmarkDedupRing(b, 1024, profile)
	checkpointBytes := d.journalCheckpointBytes
	input := newDedupBenchmarkInput(1024, profile)
	ordinaryBytes := benchmarkDispatchTransitionBytes(b,
		dispatchJournalTransition{
			Op: dispatchJournalReserve, RequestID: input.requestID, DispatchSHA256: input.digest,
			EvictedRequestID: d.keys[0],
		},
		dispatchJournalTransition{
			Op: dispatchJournalComplete, RequestID: input.requestID, DispatchSHA256: input.digest,
			Result: &input.result,
		},
		dispatchJournalTransition{
			Op: dispatchJournalAcknowledge, RequestID: input.requestID, DispatchSHA256: input.digest,
		},
	)
	b.ReportAllocs()
	b.SetBytes(checkpointBytes)
	b.ResetTimer()
	for range b.N {
		if err := d.rewriteJournalLocked(); err != nil {
			b.Fatal(err)
		}
	}
	b.StopTimer()
	lifecyclesPerCompaction := (dispatchJournalCompactAfter + 2) / 3
	b.ReportMetric(
		float64(ordinaryBytes)+float64(checkpointBytes)/float64(lifecyclesPerCompaction),
		"amortized-B/lifecycle",
	)
	b.ReportMetric(float64(checkpointBytes), "checkpoint-B")
}

func benchmarkDispatchTransitionBytes(b *testing.B, transitions ...dispatchJournalTransition) int64 {
	b.Helper()
	var total int64
	for _, transition := range transitions {
		line, err := marshalDispatchJournalLine(transition)
		if err != nil {
			b.Fatal(err)
		}
		total += int64(len(line))
	}
	return total
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
	if err := d.rewriteJournalLocked(); err != nil {
		b.Fatalf("seed dispatch checkpoint: %v", err)
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

func measureDedupLifecycleBytes(
	b *testing.B,
	d *dedupRing,
	input dedupBenchmarkInput,
) (storeBytes int64, appendedBytes int64) {
	b.Helper()
	before := dedupBenchmarkStoreSize(b, d.storePath)
	decision, _, err := d.reserve(input.requestID, input.digest)
	if err != nil || decision != reservationNew {
		b.Fatalf("measure reserve %s: decision=%v err=%v", input.requestID, decision, err)
	}
	if err := d.complete(input.requestID, input.digest, input.result); err != nil {
		b.Fatalf("measure complete %s: %v", input.requestID, err)
	}
	if err := d.acknowledge(input.requestID); err != nil {
		b.Fatalf("measure acknowledge %s: %v", input.requestID, err)
	}
	storeBytes = dedupBenchmarkStoreSize(b, d.storePath)
	appendedBytes = storeBytes - before
	return storeBytes, appendedBytes
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
