package packs

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// an untouched pack re-hashes to exactly its load-time cached
// PackHash, so the dispatch gate proceeds. (The mutation half lives in the
// existing TestRecomputePackHash_DetectsTampering; this asserts the
// equal-when-clean direction in isolation.)
func TestRecomputePackHash_EqualsCachedWhenUntouched(t *testing.T) {
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("cleanpack"),
		"actions/a.yaml": actionYAML("cleanpack.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	cached, ok := reg.PackHash("cleanpack")
	if !ok || cached == "" {
		t.Fatal("expected a cached hash after load")
	}
	for i := 0; i < 3; i++ {
		fresh, err := reg.RecomputePackHash("cleanpack")
		if err != nil {
			t.Fatal(err)
		}
		if fresh != cached {
			t.Fatalf("untouched pack rehash #%d diverged: cached=%s fresh=%s", i, cached, fresh)
		}
	}
}

// a pack present in the index but with no cached hash inputs
// errors rather than returning a hash over an empty set (which would let a
// gutted pack masquerade as a valid-but-tiny one).
func TestRecomputePackHash_EmptyInputsErrors(t *testing.T) {
	reg := newRegistry()
	// Register a pack with no hash inputs — the corrupt-internal-state case
	// the empty-inputs guard exists to fail closed on.
	reg.packs["ghost"] = &packspec.Pack{ID: "ghost"}
	if _, err := reg.RecomputePackHash("ghost"); err == nil {
		t.Fatal("expected an error when no hash inputs are cached")
	}
}

// the content hash is deterministic, order-independent, and
// injection-resistant: it is sha256 over relpath-sorted `rel\x00data\x00`
// entries, rendered as "sha256:"+hex. This recomputes the digest by hand from
// a known entry set and asserts byte-for-byte equality, and that input order
// does not change the result.
func TestComputePackHash_LayoutAndOrderIndependence(t *testing.T) {
	entries := []hashEntry{
		{rel: "pack.yaml", data: []byte("id: x\n")},
		{rel: "actions/a.yaml", data: []byte("id: x.a\n")},
		{rel: "scripts/run.sh", data: []byte("echo hi\n")},
	}

	// Independent reference digest: sort by rel, then rel\x00data\x00 per entry.
	want := func() string {
		h := sha256.New()
		for _, e := range []hashEntry{entries[1], entries[0], entries[2]} { // sorted: actions/, pack.yaml, scripts/
			h.Write([]byte(e.rel))
			h.Write([]byte{0})
			h.Write(e.data)
			h.Write([]byte{0})
		}
		return "sha256:" + hex.EncodeToString(h.Sum(nil))
	}()

	got := computePackHash(entries)
	if got != want {
		t.Fatalf("hash layout mismatch:\n got=%s\nwant=%s", got, want)
	}

	// Feeding the same entries in a different order yields the same digest
	// (computePackHash sorts internally).
	shuffled := []hashEntry{entries[2], entries[0], entries[1]}
	if other := computePackHash(shuffled); other != got {
		t.Fatalf("hash is order-dependent: %s != %s", other, got)
	}
}

// (companion) — the NUL delimiter prevents a rel/data boundary
// from being smuggled: an entry {rel:"ab", data:"cd"} must hash differently
// from {rel:"a", data:"bcd"} even though the concatenated bytes are equal.
func TestComputePackHash_DelimiterPreventsBoundaryInjection(t *testing.T) {
	a := computePackHash([]hashEntry{{rel: "ab", data: []byte("cd")}})
	b := computePackHash([]hashEntry{{rel: "a", data: []byte("bcd")}})
	if a == b {
		t.Fatal("hash must distinguish rel/data boundaries (NUL delimiter)")
	}
}

// a file ADDED to the pack dir after load (outside the recorded
// relpath set) does NOT change the re-hash. This is the documented pin
// boundary: the pin covers exactly the load-time relpath set, matching the
// cloud's trust boundary. (Paired with T10 below, which proves mutation of a
// recorded file IS caught.)
func TestRecomputePackHash_AddedFileDoesNotChangeHash(t *testing.T) {
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("addpack"),
		"actions/a.yaml": actionYAML("addpack.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	cached, _ := reg.PackHash("addpack")

	// Drop a brand-new file into the pack dir, not referenced by pack.yaml.
	if err := os.WriteFile(filepath.Join(root, "actions", "sneaked.yaml"), []byte("id: addpack.evil\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	after, err := reg.RecomputePackHash("addpack")
	if err != nil {
		t.Fatal(err)
	}
	if after != cached {
		t.Fatalf("an added (unrecorded) file must not change the pin: cached=%s after=%s", cached, after)
	}
}

// mutating any RECORDED file IS caught. Pairs with T09 to bound
// exactly what the pin covers. Uses pack.yaml (a recorded entry distinct from
// the action file the existing tampering test mutates).
func TestRecomputePackHash_MutatingRecordedFileCaught(t *testing.T) {
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("mutpack"),
		"actions/a.yaml": actionYAML("mutpack.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	cached, _ := reg.PackHash("mutpack")

	// Append a harmless comment to the recorded pack.yaml on disk.
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(packYAML("mutpack")+"# tampered\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	after, err := reg.RecomputePackHash("mutpack")
	if err != nil {
		t.Fatal(err)
	}
	if after == cached {
		t.Fatal("mutating a recorded file must change the re-hash")
	}
}

// unknown-id lookups miss cleanly across every accessor (the
// engine maps these misses to unknown_action; they must never panic or
// return a stale entry).
func TestRegistry_UnknownIDLookupsMissCleanly(t *testing.T) {
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("look"),
		"actions/a.yaml": actionYAML("look.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reg.Pack("nope"); ok {
		t.Error("Pack(unknown) returned ok=true")
	}
	if _, ok := reg.Action("nope.nope"); ok {
		t.Error("Action(unknown) returned ok=true")
	}
	if si, ok := reg.ScriptInfo("nope.nope"); ok || si.Path != "" || si.SHA256 != "" {
		t.Errorf("ScriptInfo(unknown) = (%+v, %v), want zero/false", si, ok)
	}
	if _, ok := reg.PackHash("nope"); ok {
		t.Error("PackHash(unknown) returned ok=true")
	}
}

// Packs and Actions return id-sorted slices for stable
// advertisement, independent of map iteration / insertion order.
func TestRegistry_PacksAndActionsSorted(t *testing.T) {
	tmp := t.TempDir()
	// Insert in deliberately non-alphabetical directory order.
	writePack(t, tmp, "zdir", map[string]string{
		"pack.yaml":      packYAML("zpack"),
		"actions/a.yaml": actionYAML("zpack.z"),
	})
	writePack(t, tmp, "adir", map[string]string{
		"pack.yaml":      packYAML("apack"),
		"actions/a.yaml": actionYAML("apack.a"),
	})
	writePack(t, tmp, "mdir", map[string]string{
		"pack.yaml":      packYAML("mpack"),
		"actions/a.yaml": actionYAML("mpack.m"),
	})
	reg, err := LoadAll([]string{tmp}, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}

	packs := reg.Packs()
	wantPacks := []string{"apack", "mpack", "zpack"}
	if len(packs) != len(wantPacks) {
		t.Fatalf("got %d packs, want %d", len(packs), len(wantPacks))
	}
	for i, p := range packs {
		if p.ID != wantPacks[i] {
			t.Fatalf("Packs()[%d].ID = %q, want %q (not id-sorted)", i, p.ID, wantPacks[i])
		}
	}

	actions := reg.Actions()
	wantActions := []string{"apack.a", "mpack.m", "zpack.z"}
	if len(actions) != len(wantActions) {
		t.Fatalf("got %d actions, want %d", len(actions), len(wantActions))
	}
	for i, a := range actions {
		if a.ID != wantActions[i] {
			t.Fatalf("Actions()[%d].ID = %q, want %q (not id-sorted)", i, a.ID, wantActions[i])
		}
	}
}

// the registry is read-only after load: many concurrent
// readers across every accessor are race-free (run under `go test -race`).
// The only mutation point is loader build / SIGHUP swap, never per-request.
func TestRegistry_ConcurrentReadsAreRaceFree(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "c", map[string]string{
		"pack.yaml":      packYAML("conc"),
		"actions/a.yaml": actionYAML("conc.a"),
	})
	reg, err := LoadAll([]string{tmp}, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				_, _ = reg.Action("conc.a")
				_, _ = reg.Pack("conc")
				_, _ = reg.PackHash("conc")
				_ = reg.Actions()
				_ = reg.Packs()
			}
		}()
	}
	wg.Wait()
}
