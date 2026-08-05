package packtest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMirrorsExpandCommittedVersionsAndResolveOnlyExactRefs(t *testing.T) {
	root := t.TempDir()
	packDir := filepath.Join(root, "example")
	if err := os.MkdirAll(filepath.Join(packDir, "test"), 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		filepath.Join(packDir, "pack.yaml"): "version: 1.0.0\nactions: []\n",
		filepath.Join(packDir, "test", "cases.yaml"): "services: [sut]\nversions:\n" +
			"  - {version: 2.0.0, digest: '@sha256:" + strings.Repeat("a", 64) + "', default: true}\n" +
			"  - {version: 1.9.0, digest: '@sha256:" + strings.Repeat("b", 64) + "'}\ncases: []\n",
		filepath.Join(packDir, "test", "compose.yaml"): "services:\n  sut:\n    image: ${PACKTEST_IMAGE:-vendor/example:${PACKTEST_VERSION:-2.0.0}${PACKTEST_DIGEST-}}\n",
		filepath.Join(root, "mirrors.yaml"):            "mirrors:\n  - {pack: example, source: vendor/example}\n",
	}
	for path, contents := range files {
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := Mirrors(root, filepath.Join(root, "mirrors.yaml"), "ghcr.io/example/packtest-suts")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %#v", rows)
	}
	row, ok := ResolveMirror(rows, "example", "2.0.0", "@sha256:"+strings.Repeat("a", 64))
	if !ok || row.SourceRef != "vendor/example:2.0.0@sha256:"+strings.Repeat("a", 64) ||
		row.MirrorRef != "ghcr.io/example/packtest-suts:example-2.0.0@sha256:"+strings.Repeat("a", 64) {
		t.Fatalf("resolved row = %#v, %t", row, ok)
	}
	if _, ok := ResolveMirror(rows, "example", "2.0.0", "@sha256:"+strings.Repeat("c", 64)); ok {
		t.Fatal("changed digest resolved to the mirror")
	}
}

func TestMirrorsRejectUnwiredAndAmbiguousSelections(t *testing.T) {
	root := t.TempDir()
	packDir := filepath.Join(root, "example")
	if err := os.MkdirAll(filepath.Join(packDir, "test"), 0o755); err != nil {
		t.Fatal(err)
	}
	for path, contents := range map[string]string{
		filepath.Join(packDir, "pack.yaml"):            "version: 1.0.0\nactions: []\n",
		filepath.Join(packDir, "test", "cases.yaml"):   "services: [sut]\nversions:\n  - {version: 2.0.0, digest: '@sha256:" + strings.Repeat("a", 64) + "', default: true}\ncases: []\n",
		filepath.Join(packDir, "test", "compose.yaml"): "services:\n  sut:\n    image: vendor/example:${PACKTEST_VERSION:-2.0.0}${PACKTEST_DIGEST-}\n",
	} {
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	config := filepath.Join(root, "mirrors.yaml")
	if err := os.WriteFile(config, []byte("mirrors:\n  - {pack: example, source: vendor/example}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Mirrors(root, config, "ghcr.io/example/packtest-suts"); err == nil || !strings.Contains(err.Error(), "must opt in") {
		t.Fatalf("unwired error = %v", err)
	}
	if err := os.WriteFile(config, []byte("mirrors:\n  - {pack: example, source: vendor/example}\n  - {pack: example, source: vendor/example}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Mirrors(root, config, "ghcr.io/example/packtest-suts"); err == nil || !strings.Contains(err.Error(), "more than once") {
		t.Fatalf("duplicate error = %v", err)
	}
	if _, err := Mirrors(root, config, "GHCR.IO/example/packtest-suts"); err == nil || !strings.Contains(err.Error(), "lowercase") {
		t.Fatalf("registry error = %v", err)
	}
}
