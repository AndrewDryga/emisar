package catalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// TarballObject is the immutable object path for a pack's tarball, content-
// addressed by its content hash so identical bytes always resolve to the
// same object (v1/packs/<id>/<version>/<sha256hex>/pack.tar.gz).
func TarballObject(id, version, contentHash string) string {
	return fmt.Sprintf("v1/packs/%s/%s/%s/pack.tar.gz", id, version, hashHex(contentHash))
}

// hashHex strips the "sha256:" prefix so the hash is a clean path segment.
func hashHex(contentHash string) string {
	return strings.TrimPrefix(contentHash, "sha256:")
}

// Tarball builds a deterministic gzip-compressed tar of EXACTLY a pack's
// hash-input files (from Registry.PackFiles) — pack.yaml + its referenced
// action YAMLs + scripts — with flat pack-relative entry names (pack.yaml,
// actions/…), exactly what `emisar pack install` extracts and re-hashes.
//
// Building from the hash-input set instead of a directory walk is the trust
// invariant: the archived bytes are precisely the bytes the content hash
// covers, so no unreferenced file (a stray README, a .DS_Store, an editor
// backup) can ride along inside the content-addressed object outside the hash,
// and an unchanged pack always reproduces identical archive bytes (entry order,
// mtime, ownership, and mode are all fixed) — a true no-op republish.
func Tarball(files []packs.PackFile) ([]byte, error) {
	sorted := make([]packs.PackFile, len(files))
	copy(sorted, files)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Rel < sorted[j].Rel })

	var buf bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(gz)
	for _, f := range sorted {
		rel := filepath.ToSlash(f.Rel)
		mode := int64(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		hdr := &tar.Header{
			Name:     rel,
			Mode:     mode,
			Size:     int64(len(f.Data)),
			Typeflag: tar.TypeReg,
			// Fixed metadata for byte-reproducibility — the runner hashes file
			// CONTENTS, not archive metadata, so these are cosmetic to trust
			// and load-bearing only for idempotent republishing.
			ModTime: time.Unix(0, 0).UTC(),
			Uid:     0,
			Gid:     0,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, err
		}
		if _, err := tw.Write(f.Data); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
