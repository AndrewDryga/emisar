package cloud

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

func dispatchTestLine(t *testing.T, value any) []byte {
	t.Helper()
	line, err := dispatchLogLine(value)
	if err != nil {
		t.Fatal(err)
	}
	return line
}

func reservedTestEntry(id string) dedupEntry {
	return dedupEntry{RequestID: id, DispatchSHA256: testDispatchDigest(id), State: dispatchReserved}
}

func completedTestEntry(id string) dedupEntry {
	entry := reservedTestEntry(id)
	entry.State = dispatchCompleted
	entry.Result = testActionResult(id, ActionResultMsg{EventID: "evt_" + id})
	return entry
}

func TestDedupStoreTaggedReplayAndOldReaderRefusal(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(4, path, "", nil)
	reserveCompleteAndAcknowledge(t, d, "a", testDispatchDigest("a"), ActionResultMsg{EventID: "evt_a"})
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := bytes.Split(bytes.TrimSpace(data), []byte("\n"))
	if len(lines) != 3 {
		t.Fatalf("physical records=%d, want three durable transitions", len(lines))
	}
	for _, line := range lines {
		if _, _, err := decodeDedupEntry(line); err == nil {
			t.Fatal("snapshot-only decoder accepted a transition")
		}
	}
	if report := InspectDispatchLog(filepath.Dir(path)); report.State != DispatchLogOK || report.Entries != 1 {
		t.Fatalf("inspection counted physical lines, not retained entries: %+v", report)
	}
	assertDedupRestartMatches(t, d)
	if err := d.writeStore(); err != nil {
		t.Fatal(err)
	}
	reserveAndComplete(t, d, "b", testDispatchDigest("b"), ActionResultMsg{EventID: "evt_b"})
	assertDedupRestartMatches(t, d)
}

func TestDedupStoreRejectsInvalidTransitions(t *testing.T) {
	r := reservedTestEntry("a")
	c := completedTestEntry("a")
	a := c
	a.State = dispatchAcknowledged
	other := reservedTestEntry("b")
	transition := func(entry dedupEntry, evict string) []byte {
		return dispatchTestLine(t, dispatchTransition{Version: 1, Entry: entry, Evict: evict})
	}
	lineR, lineC, lineA := dispatchTestLine(t, r), dispatchTestLine(t, c), dispatchTestLine(t, a)
	changedDigest := c
	changedDigest.DispatchSHA256 = testDispatchDigest("different")
	changedResult := a
	changedResult.Result.EventID = "evt_changed"
	unknownVersion := dispatchTestLine(t, dispatchTransition{Version: 2, Entry: r})
	unknownOuter := bytes.Replace(transition(r, ""), []byte(`"dispatch_log_version":1`), []byte(`"dispatch_log_version":1,"surprise":true`), 1)
	duplicateOuter := bytes.Replace(transition(r, ""), []byte(`"dispatch_log_version":1`), []byte(`"dispatch_log_version":1,"dispatch_log_version":1`), 1)
	duplicateNested := bytes.Replace(transition(r, ""), []byte(`"request_id":"a"`), []byte(`"request_id":"a","request_id":"a"`), 1)
	unknownNested := bytes.Replace(transition(c, ""), []byte(`"event_id":"evt_a"`), []byte(`"event_id":"evt_a","surprise":true`), 1)
	tests := []struct {
		name   string
		prefix []byte
		delta  []byte
	}{
		{"unknown version", nil, unknownVersion},
		{"unknown outer field", nil, unknownOuter},
		{"duplicate outer field", nil, duplicateOuter},
		{"duplicate nested field", nil, duplicateNested},
		{"unknown result field", lineR, unknownNested},
		{"null entry", nil, []byte("{\"dispatch_log_version\":1,\"entry\":null}\n")},
		{"legacy tagged entry", nil, []byte("{\"dispatch_log_version\":1,\"entry\":" + legacyDispatchLine("a") + "}\n")},
		{"unknown completion", nil, transition(c, "")},
		{"unknown acknowledgement", nil, transition(a, "")},
		{"duplicate reservation", lineR, transition(r, "")},
		{"changed digest", lineR, transition(changedDigest, "")},
		{"repeated completion", lineC, transition(c, "")},
		{"acknowledgement before completion", lineR, transition(a, "")},
		{"changed acknowledged result", lineC, transition(changedResult, "")},
		{"repeated acknowledgement", lineA, transition(a, "")},
		{"regression to reservation", lineC, transition(r, "")},
		{"regression to completion", lineA, transition(c, "")},
		{"evict reservation", lineR, transition(other, "a")},
		{"evict unacknowledged completion", lineC, transition(other, "a")},
		{"evict unknown", lineA, transition(other, "missing")},
		{"evict same request", lineA, transition(r, "a")},
		{"eviction on completion", append(slices.Clone(lineR), dispatchTestLine(t, dedupEntry{RequestID: "b", DispatchSHA256: other.DispatchSHA256, State: dispatchAcknowledged, Result: completedTestEntry("b").Result})...), transition(c, "b")},
		{"empty eviction", nil, bytes.Replace(transition(r, ""), []byte(`"entry":`), []byte(`"evict":"","entry":`), 1)},
		{"null eviction", nil, bytes.Replace(transition(r, ""), []byte(`"entry":`), []byte(`"evict":null,"entry":`), 1)},
		{"snapshot after transition", transition(r, ""), dispatchTestLine(t, other)},
		{"duplicate snapshot", lineR, lineR},
		{"torn trailing transition", lineR, []byte(`{"dispatch_log_version":1,"entry":`)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), dispatchLogFilename)
			body := append(slices.Clone(test.prefix), test.delta...)
			if err := os.WriteFile(path, body, 0o600); err != nil {
				t.Fatal(err)
			}
			d := newDedupRing(4, path, "", nil)
			if d.loadErr == nil {
				t.Fatal("invalid history was accepted")
			}
			assertDedupUnusable(t, d)
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, body) {
				t.Fatalf("invalid history was changed: %v", err)
			}
		})
	}
}

func TestDedupStoreNormalizesAcceptedMissingNewline(t *testing.T) {
	for _, tagged := range []bool{false, true} {
		t.Run(fmt.Sprint(tagged), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), dispatchLogFilename)
			var value any = reservedTestEntry("reserved")
			if tagged {
				value = dispatchTransition{Version: 1, Entry: reservedTestEntry("reserved")}
			}
			if err := os.WriteFile(path, bytes.TrimSuffix(dispatchTestLine(t, value), []byte("\n")), 0o600); err != nil {
				t.Fatal(err)
			}
			d := newDedupRing(4, path, "", nil)
			if d.loadErr != nil || !d.needsSnapshot {
				t.Fatalf("valid EOF must load and require normalization: %v", d.loadErr)
			}
			if _, _, err := d.reserve("new", testDispatchDigest("new")); err != nil {
				t.Fatal(err)
			}
			assertDedupRestartMatches(t, d)
		})
	}
}

func newDedupStoreFixture(t *testing.T) *dedupRing {
	t.Helper()
	d := newDedupRing(8, filepath.Join(t.TempDir(), dispatchLogFilename), "", nil)
	if _, _, err := d.reserve("reserved", testDispatchDigest("reserved")); err != nil {
		t.Fatal(err)
	}
	reserveAndComplete(t, d, "completed", testDispatchDigest("completed"), ActionResultMsg{EventID: "evt_completed"})
	reserveCompleteAndAcknowledge(t, d, "acknowledged", testDispatchDigest("acknowledged"), ActionResultMsg{EventID: "evt_acknowledged"})
	return d
}

func performDedupTestTransition(d *dedupRing, operation string) error {
	switch operation {
	case "reserve":
		decision, _, err := d.reserve("new", testDispatchDigest("new"))
		if err == nil && decision != reservationNew {
			return fmt.Errorf("unexpected reservation decision %v", decision)
		}
		return err
	case "complete":
		return d.complete("reserved", testDispatchDigest("reserved"), testActionResult("reserved", ActionResultMsg{EventID: "evt_reserved"}))
	case "acknowledge":
		return d.acknowledge("completed")
	default:
		return fmt.Errorf("unknown test operation %q", operation)
	}
}

func assertDedupRestartMatches(t *testing.T, d *dedupRing) {
	t.Helper()
	restarted := newDedupRing(d.max, d.storePath, "", nil)
	if restarted.loadErr != nil {
		t.Fatalf("restart: %v", restarted.loadErr)
	}
	if !reflect.DeepEqual(d.records, restarted.records) || !slices.Equal(d.keys, restarted.keys) {
		t.Fatalf("restart differs: memory keys=%v disk keys=%v\nmemory=%+v\ndisk=%+v", d.keys, restarted.keys, d.records, restarted.records)
	}
}

func TestDedupStoreRepairsBackingDriftBeforeEveryTransition(t *testing.T) {
	for _, drift := range []string{"missing", "empty", "valid prefix", "replacement", "same size replacement", "same inode overwrite", "growth"} {
		for _, operation := range []string{"reserve", "complete", "acknowledge"} {
			t.Run(drift+"/"+operation, func(t *testing.T) {
				d := newDedupStoreFixture(t)
				before := maps.Clone(d.records)
				body, err := os.ReadFile(d.storePath)
				if err != nil {
					t.Fatal(err)
				}
				changed := bytes.ReplaceAll(body, []byte(`"request_id":"reserved"`), []byte(`"request_id":"obsolete"`))
				switch drift {
				case "missing":
					err = os.Remove(d.storePath)
				case "empty":
					err = os.Truncate(d.storePath, 0)
				case "valid prefix":
					err = os.Truncate(d.storePath, int64(bytes.IndexByte(body, '\n')+1))
				case "replacement":
					err = fsutil.ReplaceFile(d.storePath, func(w io.Writer) error {
						return writeDispatchLine(w, dispatchTestLine(t, reservedTestEntry("obsolete")))
					})
				case "same size replacement":
					err = fsutil.ReplaceFile(d.storePath, func(w io.Writer) error { return writeDispatchLine(w, changed) })
				case "same inode overwrite":
					err = os.WriteFile(d.storePath, changed, 0o600)
					if err == nil {
						stamp := d.backing.ModTime().Add(time.Second)
						err = os.Chtimes(d.storePath, stamp, stamp)
					}
				case "growth":
					err = os.WriteFile(d.storePath, append(body, dispatchTestLine(t, dispatchTransition{Version: 1, Entry: reservedTestEntry("external")})...), 0o600)
				}
				if err != nil {
					t.Fatal(err)
				}
				if err := performDedupTestTransition(d, operation); err != nil {
					t.Fatal(err)
				}
				for id, previous := range before {
					entry, ok := d.records[id]
					if !ok || entry.DispatchSHA256 != previous.DispatchSHA256 {
						t.Fatalf("repair lost existing fact %q", id)
					}
				}
				if d.contains("obsolete") || d.contains("external") {
					t.Fatal("repair adopted replacement history")
				}
				assertDedupRestartMatches(t, d)
			})
		}
	}
}

func TestDedupStoreFailedRepairAndCompactionRetryCommittedSnapshot(t *testing.T) {
	for _, trigger := range []string{"missing", "compaction"} {
		for _, afterReplace := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/after-replace=%t", trigger, afterReplace), func(t *testing.T) {
				d := newDedupStoreFixture(t)
				before, keys := maps.Clone(d.records), slices.Clone(d.keys)
				if trigger == "missing" {
					if err := os.Remove(d.storePath); err != nil {
						t.Fatal(err)
					}
				} else {
					d.transitionCount = max(64, 3*d.max)
				}
				injected := errors.New("injected snapshot failure")
				calls := 0
				d.replaceFile = func(path string, write func(io.Writer) error) error {
					calls++
					if afterReplace {
						if err := fsutil.ReplaceFile(path, write); err != nil {
							return err
						}
					}
					return injected
				}
				for attempt := 0; attempt < 2; attempt++ {
					if err := performDedupTestTransition(d, "reserve"); !errors.Is(err, injected) {
						t.Fatalf("snapshot failure=%v", err)
					}
					if !d.needsSnapshot || !reflect.DeepEqual(before, d.records) || !slices.Equal(keys, d.keys) {
						t.Fatal("failed snapshot changed committed state or allowed later append")
					}
				}
				if calls != 2 {
					t.Fatalf("replacement retry count=%d", calls)
				}
				if afterReplace || trigger == "compaction" {
					assertDedupRestartMatches(t, d)
				}
				d.replaceFile = nil
				if err := performDedupTestTransition(d, "reserve"); err != nil {
					t.Fatal(err)
				}
				assertDedupRestartMatches(t, d)
			})
		}
	}
}

type faultDispatchFile struct {
	dispatchFile
	write    func([]byte) (int, error)
	sync     func() error
	truncate func(int64) error
	close    func() error
	stat     func() (os.FileInfo, error)
}

func (f *faultDispatchFile) Write(p []byte) (int, error) {
	if f.write != nil {
		return f.write(p)
	}
	return f.dispatchFile.Write(p)
}
func (f *faultDispatchFile) Sync() error {
	if f.sync != nil {
		return f.sync()
	}
	return f.dispatchFile.Sync()
}
func (f *faultDispatchFile) Truncate(size int64) error {
	if f.truncate != nil {
		return f.truncate(size)
	}
	return f.dispatchFile.Truncate(size)
}
func (f *faultDispatchFile) Close() error {
	if f.close != nil {
		return f.close()
	}
	return f.dispatchFile.Close()
}
func (f *faultDispatchFile) Stat() (os.FileInfo, error) {
	if f.stat != nil {
		return f.stat()
	}
	return f.dispatchFile.Stat()
}

func TestDedupStoreAppendFailureRollbackAndPoison(t *testing.T) {
	for _, failure := range []string{"write", "short write", "sync", "rollback truncate", "rollback sync"} {
		for _, operation := range []string{"reserve", "complete", "acknowledge"} {
			t.Run(failure+"/"+operation, func(t *testing.T) {
				d := newDedupStoreFixture(t)
				before, err := os.ReadFile(d.storePath)
				if err != nil {
					t.Fatal(err)
				}
				memory, keys := maps.Clone(d.records), slices.Clone(d.keys)
				injected := errors.New("injected I/O failure")
				d.openAppend = func(path string) (dispatchFile, error) {
					file, err := openSecureLocalAppend(path)
					if err != nil {
						return nil, err
					}
					wrapped := &faultDispatchFile{dispatchFile: file}
					syncCalls := 0
					if failure == "sync" || failure == "rollback sync" {
						wrapped.sync = func() error {
							syncCalls++
							if syncCalls == 1 || failure == "rollback sync" {
								return injected
							}
							return file.Sync()
						}
					} else {
						wrapped.write = func(p []byte) (int, error) {
							n, err := file.Write(p[:len(p)/2])
							if err != nil {
								return n, err
							}
							if failure == "short write" {
								return n, nil
							}
							return n, injected
						}
					}
					if failure == "rollback truncate" {
						wrapped.truncate = func(int64) error { return injected }
					}
					return wrapped, nil
				}
				if err := performDedupTestTransition(d, operation); err == nil {
					t.Fatal("faulted transition succeeded")
				} else if failure == "short write" && !errors.Is(err, io.ErrShortWrite) {
					t.Fatalf("short-write cause was lost: %v", err)
				} else if failure != "short write" && !errors.Is(err, injected) {
					t.Fatalf("I/O cause was lost: %v", err)
				}
				if !reflect.DeepEqual(memory, d.records) || !slices.Equal(keys, d.keys) {
					t.Fatal("failed transition modified committed memory")
				}
				if strings.HasPrefix(failure, "rollback ") {
					d.openAppend = func(string) (dispatchFile, error) { t.Fatal("poisoned ring attempted I/O"); return nil, injected }
					assertDedupUnusable(t, d)
					return
				}
				after, err := os.ReadFile(d.storePath)
				if err != nil || !bytes.Equal(before, after) {
					t.Fatalf("rollback changed durable bytes: %v", err)
				}
				assertDedupRestartMatches(t, d)
				d.openAppend = nil
				if err := performDedupTestTransition(d, operation); err != nil {
					t.Fatal(err)
				}
				assertDedupRestartMatches(t, d)
			})
		}
	}
}

func assertDedupUnusable(t *testing.T, d *dedupRing) {
	t.Helper()
	if _, _, err := d.reserve("new", testDispatchDigest("new")); err == nil {
		t.Fatal("unusable reserve succeeded")
	}
	if _, _, err := d.inspect("reserved", testDispatchDigest("reserved")); err == nil {
		t.Fatal("unusable inspect succeeded")
	}
	for _, id := range []string{"reserved", "completed", "acknowledged", "missing"} {
		if err := d.complete(id, testDispatchDigest(id), completedTestEntry(id).Result); err == nil {
			t.Fatal("unusable completion succeeded")
		}
		if err := d.acknowledge(id); err == nil {
			t.Fatal("unusable acknowledgement succeeded")
		}
		if _, ok := d.unacknowledgedResult(id); ok {
			t.Fatal("unusable ring exposed result")
		}
		if _, ok := d.lookup(id); ok {
			t.Fatal("unusable ring replayed result")
		}
		if d.contains(id) {
			t.Fatal("unusable ring exposed membership")
		}
	}
	if len(d.unacknowledgedResults()) != 0 {
		t.Fatal("unusable ring exposed reconciliation results")
	}
}

func TestDedupStoreCloseFailureAfterCommitIsNotRetried(t *testing.T) {
	for _, operation := range []string{"reserve", "complete", "acknowledge"} {
		t.Run(operation, func(t *testing.T) {
			d := newDedupStoreFixture(t)
			before, err := os.ReadFile(d.storePath)
			if err != nil {
				t.Fatal(err)
			}
			d.openAppend = func(path string) (dispatchFile, error) {
				file, err := openSecureLocalAppend(path)
				if err != nil {
					return nil, err
				}
				return &faultDispatchFile{dispatchFile: file, close: func() error {
					if err := file.Close(); err != nil {
						return err
					}
					return errors.New("injected close after real close")
				}}, nil
			}
			if err := performDedupTestTransition(d, operation); err != nil {
				t.Fatalf("committed operation failed: %v", err)
			}
			after, err := os.ReadFile(d.storePath)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Count(after, []byte("\n")) != bytes.Count(before, []byte("\n"))+1 {
				t.Fatal("expected exactly one new transition")
			}
			assertDedupRestartMatches(t, d)
			if operation == "reserve" {
				if decision, _, err := d.reserve("new", testDispatchDigest("new")); err != nil || decision != reservationPending {
					t.Fatalf("retry=%v %v", decision, err)
				}
			} else if err := performDedupTestTransition(d, operation); err != nil {
				t.Fatal(err)
			}
			retried, err := os.ReadFile(d.storePath)
			if err != nil || !bytes.Equal(after, retried) {
				t.Fatalf("retry appended a duplicate: %v", err)
			}
		})
	}
}

func TestDedupStorePrewriteFailuresAreRetryable(t *testing.T) {
	for _, failure := range []string{"open", "stat"} {
		for _, operation := range []string{"reserve", "complete", "acknowledge"} {
			t.Run(failure+"/"+operation, func(t *testing.T) {
				d := newDedupStoreFixture(t)
				before := maps.Clone(d.records)
				original, err := os.ReadFile(d.storePath)
				if err != nil {
					t.Fatal(err)
				}
				injected := errors.New("injected prewrite failure")
				d.openAppend = func(path string) (dispatchFile, error) {
					if failure == "open" {
						return nil, injected
					}
					file, err := openSecureLocalAppend(path)
					if err != nil {
						return nil, err
					}
					return &faultDispatchFile{dispatchFile: file, stat: func() (os.FileInfo, error) {
						return nil, injected
					}}, nil
				}
				if err := performDedupTestTransition(d, operation); !errors.Is(err, injected) {
					t.Fatalf("lost prewrite error: %v", err)
				}
				got, err := os.ReadFile(d.storePath)
				if err != nil || !bytes.Equal(original, got) || !reflect.DeepEqual(before, d.records) || d.persistErr != nil {
					t.Fatalf("prewrite failure changed committed state or poisoned the ring: %v", err)
				}
				d.openAppend = nil
				if err := performDedupTestTransition(d, operation); err != nil {
					t.Fatal(err)
				}
				assertDedupRestartMatches(t, d)
			})
		}
	}
}

func TestDedupStoreCompactionAndStartupPruningStayBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(3, path, "", nil)
	replacements := 0
	d.replaceFile = func(path string, write func(io.Writer) error) error {
		replacements++
		return fsutil.ReplaceFile(path, write)
	}
	for i := 0; i < 100; i++ {
		id := fmt.Sprintf("req-%03d", i)
		reserveCompleteAndAcknowledge(t, d, id, testDispatchDigest(id), ActionResultMsg{EventID: "evt"})
	}
	if replacements < 2 || d.transitionCount >= 64 {
		t.Fatalf("compaction did not bound history: replacements=%d transitions=%d", replacements, d.transitionCount)
	}
	assertDedupRestartMatches(t, d)
	pruned := newDedupRing(1, path, "", nil)
	if !pruned.needsSnapshot || len(pruned.keys) != 1 || pruned.keys[0] != "req-099" {
		t.Fatalf("pruning=%v dirty=%v", pruned.keys, pruned.needsSnapshot)
	}
	if _, _, err := pruned.reserve("new", testDispatchDigest("new")); err != nil {
		t.Fatal(err)
	}
	largeAgain := newDedupRing(1000, path, "", nil)
	if largeAgain.loadErr != nil || len(largeAgain.records) != 1 || !largeAgain.contains("new") {
		t.Fatalf("pruned records reappeared: %v %v", largeAgain.keys, largeAgain.loadErr)
	}
}

func TestDedupStoreSnapshotRetainsUnacknowledgedEntriesAboveCapacity(t *testing.T) {
	d := newDedupStoreFixture(t)
	pruned := newDedupRing(1, d.storePath, "", nil)
	if len(pruned.records) != 2 || pruned.contains("acknowledged") {
		t.Fatalf("pruned active entries: %v", pruned.keys)
	}
	if err := performDedupTestTransition(pruned, "complete"); err != nil {
		t.Fatal(err)
	}
	assertDedupRestartMatches(t, pruned)
	if _, _, err := pruned.reserve("new", testDispatchDigest("new")); err == nil {
		t.Fatal("capacity ignored active/unacknowledged entries")
	}
}

func TestDedupStoreRejectedOversizedTransitionLeavesReservation(t *testing.T) {
	d := newDedupStoreFixture(t)
	result := completedTestEntry("reserved").Result
	result.ExecutedCommand = strings.Repeat("x", maxDispatchLogLineBytes)
	if err := d.complete("reserved", testDispatchDigest("reserved"), result); err == nil {
		t.Fatal("wrote an unreadable oversized record")
	}
	if decision, _, err := d.inspect("reserved", testDispatchDigest("reserved")); err != nil || decision != reservationPending {
		t.Fatalf("oversized result changed reservation: %v %v", decision, err)
	}
	assertDedupRestartMatches(t, d)
}

func TestDedupStoreSnapshotAcceptsLargeRetainedHistory(t *testing.T) {
	d := newDedupRing(64, filepath.Join(t.TempDir(), dispatchLogFilename), "", nil)
	for i := 0; i < 64; i++ {
		id := fmt.Sprintf("large-%d", i)
		entry := completedTestEntry(id)
		entry.Result.ExecutedCommand = strings.Repeat("x", 32<<10)
		entry.State = dispatchAcknowledged
		d.keys = append(d.keys, id)
		d.records[id] = entry
	}
	if err := d.writeStore(); err != nil {
		t.Fatal(err)
	}
	if d.snapshotBytes <= 1<<20 {
		t.Fatal("fixture must exceed the minimum byte budget")
	}
	if _, _, err := d.reserve("new", testDispatchDigest("new")); err != nil {
		t.Fatal(err)
	}
	assertDedupRestartMatches(t, d)
}

func TestDedupStoreByteBudgetCompactsBeforeTransitionBudget(t *testing.T) {
	d := newDedupRing(128, filepath.Join(t.TempDir(), dispatchLogFilename), "", nil)
	replacements := 0
	d.replaceFile = func(path string, write func(io.Writer) error) error {
		replacements++
		return fsutil.ReplaceFile(path, write)
	}
	for i := 0; i < 48; i++ {
		id := fmt.Sprintf("large-%d", i)
		result := ActionResultMsg{
			EventID: "evt", ExecutedCommand: strings.Repeat("x", maxExecutedCommandBytes),
			StructuredOutput: json.RawMessage(`{"value":"` + strings.Repeat("x", 7<<10) + `"}`),
		}
		reserveCompleteAndAcknowledge(t, d, id, testDispatchDigest(id), result)
		if d.appendBytes > max(int64(1<<20), d.snapshotBytes) {
			t.Fatalf("byte budget exceeded: appended=%d snapshot=%d", d.appendBytes, d.snapshotBytes)
		}
	}
	// 144 transitions cannot reach the 384-transition threshold; replacements
	// beyond the initial snapshot therefore exercise the independent byte cap.
	if replacements < 2 {
		t.Fatal("byte budget failed to compact a large-result history")
	}
	assertDedupRestartMatches(t, d)
}

func TestDedupStoreReplayIgnoresCapacityUntilExplicitEviction(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	a := completedTestEntry("a")
	a.State = dispatchAcknowledged
	b := reservedTestEntry("b")
	body := append(dispatchTestLine(t, a), dispatchTestLine(t, dispatchTransition{Version: 1, Entry: b})...)
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	entries, _, err := readDispatchLog(path)
	if err != nil || len(entries) != 2 {
		t.Fatalf("replay inferred an eviction: %d %v", len(entries), err)
	}
	transition := dispatchTransition{Version: 1, Entry: reservedTestEntry("c"), Evict: "a"}
	if err := os.WriteFile(path, append(body, dispatchTestLine(t, transition)...), 0o600); err != nil {
		t.Fatal(err)
	}
	entries, _, err = readDispatchLog(path)
	if err != nil || len(entries) != 2 || entries[0].RequestID != "b" || entries[1].RequestID != "c" {
		t.Fatalf("explicit eviction/order lost: %+v %v", entries, err)
	}
}
