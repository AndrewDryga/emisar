package catalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
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

// Tarball builds a deterministic gzip-compressed tar of every regular file
// under packRoot, with flat pack-relative entry names (pack.yaml, actions/…)
// — exactly what `emisar pack install` extracts and re-hashes. Entry order,
// mtime, ownership, and mode are fixed so the same pack bytes always produce
// the same archive bytes, making a republish of an unchanged pack a true
// no-op against the immutable object path.
func Tarball(packRoot string) ([]byte, error) {
	var rels []string
	err := filepath.WalkDir(packRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		// Follow symlinks (a pack may opt into them); include only regular
		// files, matching the loader's trust boundary and the portal tarball.
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(packRoot, path)
		if err != nil {
			return err
		}
		rels = append(rels, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("catalog: walk pack %s: %w", packRoot, err)
	}
	sort.Strings(rels)

	var buf bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(gz)
	for _, rel := range rels {
		data, err := os.ReadFile(filepath.Join(packRoot, filepath.FromSlash(rel)))
		if err != nil {
			return nil, fmt.Errorf("catalog: read %s: %w", rel, err)
		}
		mode := int64(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		hdr := &tar.Header{
			Name:     rel,
			Mode:     mode,
			Size:     int64(len(data)),
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
		if _, err := tw.Write(data); err != nil {
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
