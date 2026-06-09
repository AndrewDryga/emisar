package packs

import (
	"os"
	"path/filepath"
	"testing"
)

// TestRecomputePackHash_DetectsTampering is the runner-side trust check: the
// cached PackHash is fixed at load time; RecomputePackHash asks "what's the
// hash right now?" so the dispatch path can refuse a pack whose files were
// changed under it after the operator (and cloud) trusted them.
func TestRecomputePackHash_DetectsTampering(t *testing.T) {
	tmp := t.TempDir()
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("trustpack"),
		"actions/a.yaml": actionYAML("trustpack.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}

	cached, ok := reg.PackHash("trustpack")
	if !ok || cached == "" {
		t.Fatal("expected a cached pack hash after load")
	}

	// Unchanged on disk → recompute equals the cached hash.
	fresh, err := reg.RecomputePackHash("trustpack")
	if err != nil {
		t.Fatal(err)
	}
	if fresh != cached {
		t.Fatalf("unchanged pack should rehash equal: cached=%s fresh=%s", cached, fresh)
	}

	// Tamper an action file on disk → recompute must diverge from the trusted
	// hash so the dispatch path can refuse to run it.
	tampered := actionYAML("trustpack.a") + "\n# injected after trust\n"
	if err := os.WriteFile(filepath.Join(root, "actions", "a.yaml"), []byte(tampered), 0o644); err != nil {
		t.Fatal(err)
	}
	after, err := reg.RecomputePackHash("trustpack")
	if err != nil {
		t.Fatal(err)
	}
	if after == cached {
		t.Fatal("a tampered pack must produce a different hash than the trusted one")
	}
}

func TestRecomputePackHash_UnknownPack(t *testing.T) {
	reg := newRegistry()
	if _, err := reg.RecomputePackHash("nope"); err == nil {
		t.Fatal("recompute on an unloaded pack must error")
	}
}

// TestRecomputePackHash_MissingFileErrors — if a hash-input file is removed
// after load, rehashing surfaces the read error rather than silently hashing a
// short set (which could otherwise mask tampering as a smaller-but-valid pack).
func TestRecomputePackHash_MissingFileErrors(t *testing.T) {
	tmp := t.TempDir()
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("gone"),
		"actions/a.yaml": actionYAML("gone.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "actions", "a.yaml")); err != nil {
		t.Fatal(err)
	}
	if _, err := reg.RecomputePackHash("gone"); err == nil {
		t.Fatal("rehash with a missing input file must error")
	}
}
