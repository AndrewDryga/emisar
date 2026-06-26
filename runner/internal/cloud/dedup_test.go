package cloud

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestDedupRing_RememberAndLookup(t *testing.T) {
	d := newDedupRing(4, "", nil)
	d.remember("a", ActionResultMsg{EventID: "evt_a"})
	d.remember("b", ActionResultMsg{EventID: "evt_b"})

	if r, ok := d.lookup("a"); !ok || r.EventID != "evt_a" {
		t.Fatalf("a not found: %+v", r)
	}
	if r, ok := d.lookup("b"); !ok || r.EventID != "evt_b" {
		t.Fatalf("b not found: %+v", r)
	}
	if _, ok := d.lookup("missing"); ok {
		t.Fatal("missing should be absent")
	}
}

func TestDedupRing_EvictsOldest(t *testing.T) {
	d := newDedupRing(2, "", nil)
	d.remember("a", ActionResultMsg{EventID: "evt_a"})
	d.remember("b", ActionResultMsg{EventID: "evt_b"})
	d.remember("c", ActionResultMsg{EventID: "evt_c"})

	if _, ok := d.lookup("a"); ok {
		t.Fatal("a should have been evicted")
	}
	if _, ok := d.lookup("b"); !ok {
		t.Fatal("b should still be cached")
	}
	if _, ok := d.lookup("c"); !ok {
		t.Fatal("c should still be cached")
	}
	if d.size() != 2 {
		t.Fatalf("size=%d", d.size())
	}
}

func TestDedupRing_DuplicateRememberIsNoop(t *testing.T) {
	d := newDedupRing(4, "", nil)
	d.remember("a", ActionResultMsg{EventID: "evt_first"})
	d.remember("a", ActionResultMsg{EventID: "evt_second"}) // should be ignored
	r, _ := d.lookup("a")
	if r.EventID != "evt_first" {
		t.Fatalf("duplicate remember should be ignored; got %s", r.EventID)
	}
}

// TestDedupRing_SurvivesRestart is the core regression for the double-execution
// bug: a completed result must replay from disk after a "restart" (a fresh ring
// over the same store), so a re-dispatch never re-runs a mutating action.
func TestDedupRing_SurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d1 := newDedupRing(4, path, nil)
	d1.remember("req-1", ActionResultMsg{EventID: "evt_1", Status: "success", ExitCode: 0})

	d2 := newDedupRing(4, path, nil)
	r, ok := d2.lookup("req-1")
	if !ok || r.EventID != "evt_1" || r.Status != "success" {
		t.Fatalf("result did not survive restart: ok=%v %+v", ok, r)
	}
}

func TestDedupRing_PersistedRingStaysBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d1 := newDedupRing(2, path, nil)
	d1.remember("a", ActionResultMsg{EventID: "evt_a"})
	d1.remember("b", ActionResultMsg{EventID: "evt_b"})
	d1.remember("c", ActionResultMsg{EventID: "evt_c"}) // evicts a, on disk too

	d2 := newDedupRing(2, path, nil)
	if _, ok := d2.lookup("a"); ok {
		t.Fatal("evicted entry should not persist")
	}
	if _, ok := d2.lookup("c"); !ok {
		t.Fatal("recent entry should persist")
	}
	if d2.size() != 2 {
		t.Fatalf("reloaded size=%d, want 2", d2.size())
	}
}

// TestDedupRing_SkipsTornLine proves a crash mid-write (a torn trailing line)
// doesn't break load — the good entries still come back.
func TestDedupRing_SkipsTornLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	good, err := json.Marshal(dedupEntry{RequestID: "good", Result: ActionResultMsg{EventID: "evt_good"}})
	if err != nil {
		t.Fatal(err)
	}
	contents := append(append(good, '\n'), []byte(`{"request_id":"torn","resu`)...)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, path, nil)
	if _, ok := d.lookup("good"); !ok {
		t.Fatal("good entry should load past a torn trailing line")
	}
	if _, ok := d.lookup("torn"); ok {
		t.Fatal("torn entry should be skipped")
	}
}

// TestDedupRing_ConcurrentRemember exercises the lock under -race: concurrent
// remembers (each persisting the whole ring) must not race or corrupt state.
func TestDedupRing_ConcurrentRemember(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d := newDedupRing(1000, path, nil)

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			id := fmt.Sprintf("req-%d", n)
			d.remember(id, ActionResultMsg{EventID: "evt"})
			d.lookup(id)
		}(i)
	}
	wg.Wait()

	if d.size() != 50 {
		t.Fatalf("size=%d, want 50", d.size())
	}
	if _, ok := newDedupRing(1000, path, nil).lookup("req-25"); !ok {
		t.Fatal("a concurrently-remembered entry should have persisted")
	}
}
