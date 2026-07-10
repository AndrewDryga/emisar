package catalog

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// Object is one published artifact in the built tree, described so the
// publish step knows how to upload it without re-deriving intent.
type Object struct {
	// Path is the object path relative to the bucket root, e.g.
	// v1/catalog.json or v1/packs/<id>/<version>/<hex>/pack.tar.gz.
	Path string `json:"path"`
	// Immutable objects are content-addressed and uploaded with an
	// if-generation-match:0 precondition (never overwritten). Mutable
	// pointers (the latest catalog.json/suggest.json) are overwritten,
	// relying on bucket versioning to retain prior generations.
	Immutable   bool   `json:"immutable"`
	ContentType string `json:"content_type"`
	Size        int    `json:"size"`
	SHA256      string `json:"sha256"`
}

// Manifest describes a built artifact tree. It is written to the tree root
// as manifest.json (outside v1/, so it is not itself published) and read by
// the publish step.
type Manifest struct {
	SchemaVersion int      `json:"schema_version"`
	CatalogHash   string   `json:"catalog_hash"`
	Objects       []Object `json:"objects"`
}

const (
	contentTypeJSON = "application/json"
	contentTypeGzip = "application/gzip"
)

// Write lays out the full artifact tree for cat under outDir and returns its
// manifest. reg supplies the on-disk pack roots the tarballs are built from;
// it must be the same registry cat was built from.
func Write(reg *packs.Registry, cat *Catalog, outDir string) (*Manifest, error) {
	catalogBytes, err := marshalJSON(cat)
	if err != nil {
		return nil, err
	}
	catalogHash := hex.EncodeToString(sha256Sum(catalogBytes))

	m := &Manifest{SchemaVersion: SchemaVersion, CatalogHash: catalogHash}
	add := func(path string, immutable bool, ct string, data []byte) error {
		if err := writeObject(outDir, path, data); err != nil {
			return err
		}
		m.Objects = append(m.Objects, Object{
			Path:        path,
			Immutable:   immutable,
			ContentType: ct,
			Size:        len(data),
			SHA256:      hex.EncodeToString(sha256Sum(data)),
		})
		return nil
	}

	// Latest pointer (mutable) + its immutable content-addressed snapshot.
	if err := add("v1/catalog.json", false, contentTypeJSON, catalogBytes); err != nil {
		return nil, err
	}
	if err := add("v1/catalog/"+catalogHash+".json", true, contentTypeJSON, catalogBytes); err != nil {
		return nil, err
	}

	suggestBytes, err := marshalJSON(cat.Suggest())
	if err != nil {
		return nil, err
	}
	if err := add("v1/suggest.json", false, contentTypeJSON, suggestBytes); err != nil {
		return nil, err
	}

	// Schemas — immutable (versioned by their $id / the v1 prefix).
	for _, name := range sortedKeys(Schemas()) {
		if err := add("v1/schemas/"+name, true, contentTypeJSON, Schemas()[name]); err != nil {
			return nil, err
		}
	}

	// One immutable tarball per pack, content-addressed.
	for _, p := range cat.Packs {
		pack, ok := reg.Pack(p.ID)
		if !ok {
			return nil, fmt.Errorf("catalog: pack %q not in registry", p.ID)
		}
		tarball, err := Tarball(pack.Root)
		if err != nil {
			return nil, err
		}
		if err := add(TarballObject(p.ID, p.Version, p.ContentHash), true, contentTypeGzip, tarball); err != nil {
			return nil, err
		}
	}

	manifestBytes, err := marshalJSON(m)
	if err != nil {
		return nil, err
	}
	if err := writeObject(outDir, "manifest.json", manifestBytes); err != nil {
		return nil, err
	}
	return m, nil
}

func writeObject(outDir, objPath string, data []byte) error {
	full := filepath.Join(outDir, filepath.FromSlash(objPath))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	return os.WriteFile(full, data, 0o644)
}

// marshalJSON encodes v deterministically with 2-space indentation and
// without HTML escaping, so argv templates and descriptions containing
// <, >, & stay legible. The trailing newline the encoder adds is kept.
func marshalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func sha256Sum(data []byte) []byte {
	sum := sha256.Sum256(data)
	return sum[:]
}

func sortedKeys(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
