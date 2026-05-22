package cloud

import "testing"

func TestDedupRing_RememberAndLookup(t *testing.T) {
	d := newDedupRing(4)
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
	d := newDedupRing(2)
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
	d := newDedupRing(4)
	d.remember("a", ActionResultMsg{EventID: "evt_first"})
	d.remember("a", ActionResultMsg{EventID: "evt_second"}) // should be ignored
	r, _ := d.lookup("a")
	if r.EventID != "evt_first" {
		t.Fatalf("duplicate remember should be ignored; got %s", r.EventID)
	}
}
