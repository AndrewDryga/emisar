// Package packs implements pack discovery, loading, and the in-memory
// registry the engine consults at execution time.
//
// Pack discovery:
//
//   - A configured path that contains pack.yaml is treated as a single pack.
//   - Otherwise the path is treated as a parent directory; every immediate
//     child that contains a pack.yaml is loaded.
//
// All references inside a pack (action paths, script paths) are resolved
// relative to the pack root and must remain inside it. Duplicate action
// IDs (within or across packs) abort the load — fail closed.
package packs

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// LoadOptions controls loader behaviour. The zero value works for the
// common case.
type LoadOptions struct {
	// Logger is the structured logger used for load-time events
	// (duplicate IDs, etc.). Defaults to slog.Default.
	Logger *slog.Logger
}

func (o LoadOptions) logger() *slog.Logger {
	if o.Logger != nil {
		return o.Logger
	}
	return slog.Default()
}

// LoadAll discovers and loads packs from each path in dirs. The runner fails
// closed if any pack is invalid.
func LoadAll(dirs []string, opts LoadOptions) (*Registry, error) {
	reg := newRegistry()
	for _, root := range dirs {
		info, err := os.Stat(root)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("packs: stat %s: %w", root, err)
		}
		if !info.IsDir() {
			return nil, fmt.Errorf("packs: %s is not a directory", root)
		}
		if _, err := os.Stat(filepath.Join(root, "pack.yaml")); err == nil {
			if err := loadPackInto(reg, root, opts); err != nil {
				return nil, err
			}
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			return nil, fmt.Errorf("packs: list %s: %w", root, err)
		}
		for _, e := range entries {
			// Pack installation stages and recovery backups are hidden siblings.
			// Never parse them during SIGHUP; only the public target directory is
			// eligible for the live registry.
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			sub := filepath.Join(root, e.Name())
			if _, err := os.Stat(filepath.Join(sub, "pack.yaml")); err != nil {
				continue
			}
			if err := loadPackInto(reg, sub, opts); err != nil {
				return nil, err
			}
		}
	}
	return reg, nil
}

// LoadOne loads a single pack at root (which must contain pack.yaml). Used
// by `emisar pack validate`.
func LoadOne(root string, opts LoadOptions) (*Registry, error) {
	if _, err := os.Stat(filepath.Join(root, "pack.yaml")); err != nil {
		return nil, fmt.Errorf("packs: no pack.yaml at %s: %w", root, err)
	}
	reg := newRegistry()
	if err := loadPackInto(reg, root, opts); err != nil {
		return nil, err
	}
	return reg, nil
}

func loadPackInto(reg *Registry, root string, opts LoadOptions) error {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("packs: resolve %s: %w", root, err)
	}
	manifestPath := filepath.Join(absRoot, "pack.yaml")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return fmt.Errorf("packs: read %s: %w", manifestPath, err)
	}
	var pack packspec.Pack
	if err := decodeYAMLDocument(data, &pack); err != nil {
		return fmt.Errorf("packs: parse %s: %w", manifestPath, err)
	}
	pack.Root = absRoot
	if err := pack.Validate(); err != nil {
		return err
	}
	if existing, dup := reg.packs[pack.ID]; dup {
		opts.logger().Error("pack.duplicate_id",
			"pack_id", pack.ID,
			"first", existing.Root,
			"second", absRoot,
		)
		return fmt.Errorf("packs: duplicate pack id %q (first=%s second=%s)", pack.ID, existing.Root, absRoot)
	}
	reg.packs[pack.ID] = &pack
	reg.packHashInputs[pack.ID] = []hashEntry{
		{rel: "pack.yaml", data: data},
	}

	for _, relPath := range pack.Actions {
		action, data, err := loadActionFile(absRoot, relPath, pack.ID, pack.AllowSymlinks)
		if err != nil {
			return err
		}
		if existing, dup := reg.actions[action.ID]; dup {
			opts.logger().Error("action.duplicate_id",
				"action_id", action.ID,
				"first_pack", existing.PackID,
				"first_path", existing.SourcePath,
				"second_pack", pack.ID,
				"second_path", action.SourcePath,
			)
			return fmt.Errorf("packs: duplicate action id %q (first=%s second=%s)",
				action.ID, existing.SourcePath, action.SourcePath)
		}
		if action.Kind == actionspec.KindScript {
			si, scriptBytes, err := resolveScript(absRoot, action.Execution.Script.Path, action.ID, pack.AllowSymlinks)
			if err != nil {
				return err
			}
			reg.scripts[action.ID] = si
			reg.packHashInputs[pack.ID] = append(reg.packHashInputs[pack.ID],
				hashEntry{rel: action.Execution.Script.Path, data: scriptBytes})
		}
		reg.actions[action.ID] = action
		reg.packHashInputs[pack.ID] = append(reg.packHashInputs[pack.ID],
			hashEntry{rel: relPath, data: data})
	}
	// setup.verify must name one of this pack's own actions — a typo here
	// would otherwise ship a broken "run this to verify" hint.
	if v := pack.Setup.Verify; v != "" {
		act, ok := reg.actions[v]
		if !ok || act.PackID != pack.ID {
			return fmt.Errorf("packs: pack %s setup.verify %q is not an action in this pack", pack.ID, v)
		}
	}
	reg.packHashes[pack.ID] = computePackHash(reg.packHashInputs[pack.ID])
	return nil
}

type hashEntry struct {
	rel  string
	data []byte
}

func computePackHash(entries []hashEntry) string {
	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })
	h := sha256.New()
	for _, e := range entries {
		h.Write([]byte(e.rel))
		h.Write([]byte{0})
		h.Write(e.data)
		h.Write([]byte{0})
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil))
}

func loadActionFile(packRoot, rel, packID string, allowSymlinks bool) (*actionspec.Action, []byte, error) {
	src, err := resolveInsidePack(packRoot, rel, allowSymlinks)
	if err != nil {
		return nil, nil, fmt.Errorf("packs: action path %s: %w", rel, err)
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return nil, nil, fmt.Errorf("packs: read action %s: %w", src, err)
	}
	var action actionspec.Action
	if err := decodeYAMLDocument(data, &action); err != nil {
		return nil, nil, fmt.Errorf("packs: parse action %s: %w", src, err)
	}
	action.PackID = packID
	action.PackRoot = packRoot
	action.SourcePath = src
	if err := action.Validate(); err != nil {
		return nil, nil, err
	}
	return &action, data, nil
}

func decodeYAMLDocument(data []byte, destination any) error {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&yaml.Node{}); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple YAML documents are not allowed")
		}
		return err
	}
	return nil
}

// resolveInsidePack joins rel under packRoot and verifies the result is
// still under packRoot — both lexically and after EvalSymlinks.
//
// rel must not be absolute. When allowSymlinks is false (the default),
// any symlink in the resolved path causes a rejection: this prevents
// `evil-link -> /etc/passwd` from being smuggled in via a YAML reference
// that looks contained but actually points elsewhere.
func resolveInsidePack(packRoot, rel string, allowSymlinks bool) (string, error) {
	if rel == "" {
		return "", fmt.Errorf("path is empty")
	}
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("path %s must be relative to pack root", rel)
	}
	full := filepath.Clean(filepath.Join(packRoot, rel))
	if !isUnder(packRoot, full) {
		return "", fmt.Errorf("path %s escapes pack root", rel)
	}
	if _, err := os.Stat(full); err != nil {
		return "", fmt.Errorf("path %s missing: %w", rel, err)
	}
	// Resolve symlinks on both sides and re-check containment. A
	// symlink inside the pack pointing outside the pack root would
	// pass the lexical isUnder above but fail this re-check.
	resolvedFull, err := filepath.EvalSymlinks(full)
	if err != nil {
		return "", fmt.Errorf("path %s resolve: %w", rel, err)
	}
	resolvedRoot, err := filepath.EvalSymlinks(packRoot)
	if err != nil {
		return "", fmt.Errorf("pack root resolve: %w", err)
	}
	if !isUnder(resolvedRoot, resolvedFull) {
		return "", fmt.Errorf("path %s escapes pack root via symlink", rel)
	}
	// Reject symlinks introduced *inside* the pack — i.e., a symlink
	// at any segment between resolvedRoot and resolvedFull. Symlinks
	// in the directory chain ABOVE the pack root (e.g., macOS's
	// /var → /private/var) are irrelevant here.
	if !allowSymlinks {
		if symlinked, err := hasSymlinkInside(packRoot, full); err != nil {
			return "", err
		} else if symlinked {
			return "", fmt.Errorf("path %s is a symlink (pack must set allow_symlinks: true to opt in)", rel)
		}
	}
	return full, nil
}

// hasSymlinkInside reports whether any path segment from packRoot
// (exclusive) to full (inclusive) is a symlink.
func hasSymlinkInside(packRoot, full string) (bool, error) {
	rel, err := filepath.Rel(packRoot, full)
	if err != nil {
		return false, err
	}
	if rel == "." {
		return false, nil
	}
	cur := packRoot
	for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		if seg == "" {
			continue
		}
		cur = filepath.Join(cur, seg)
		info, err := os.Lstat(cur)
		if err != nil {
			return false, nil // missing component; let upstream handle
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return true, nil
		}
	}
	return false, nil
}

func isUnder(root, candidate string) bool {
	rootClean := filepath.Clean(root)
	cand := filepath.Clean(candidate)
	if cand == rootClean {
		return true
	}
	rel, err := filepath.Rel(rootClean, cand)
	if err != nil {
		return false
	}
	if rel == "." {
		return true
	}
	if strings.HasPrefix(rel, "..") {
		return false
	}
	return true
}

func resolveScript(packRoot, rel, actionID string, allowSymlinks bool) (ScriptInfo, []byte, error) {
	full, err := resolveInsidePack(packRoot, rel, allowSymlinks)
	if err != nil {
		return ScriptInfo{}, nil, fmt.Errorf("packs: action %s: script: %w", actionID, err)
	}
	if _, err := os.Stat(full); err != nil {
		return ScriptInfo{}, nil, fmt.Errorf("packs: action %s: stat script: %w", actionID, err)
	}
	si := ScriptInfo{Path: full}
	data, err := os.ReadFile(full)
	if err != nil {
		return ScriptInfo{}, nil, fmt.Errorf("packs: action %s: read script: %w", actionID, err)
	}
	h := sha256.Sum256(data)
	si.SHA256 = hex.EncodeToString(h[:])
	return si, data, nil
}
