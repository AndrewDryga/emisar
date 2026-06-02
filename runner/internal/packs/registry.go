package packs

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// ScriptInfo is the cached metadata for a script-kind action's payload.
type ScriptInfo struct {
	Path   string
	SHA256 string
	Size   int64
}

// Registry is the in-memory index of loaded packs and actions.
type Registry struct {
	packs          map[string]*packspec.Pack
	actions        map[string]*actionspec.Action
	scripts        map[string]ScriptInfo
	packHashes     map[string]string
	packHashInputs map[string][]hashEntry
}

func newRegistry() *Registry {
	return &Registry{
		packs:          map[string]*packspec.Pack{},
		actions:        map[string]*actionspec.Action{},
		scripts:        map[string]ScriptInfo{},
		packHashes:     map[string]string{},
		packHashInputs: map[string][]hashEntry{},
	}
}

// Pack returns a pack by id.
func (r *Registry) Pack(id string) (*packspec.Pack, bool) {
	p, ok := r.packs[id]
	return p, ok
}

// Action returns an action by id.
func (r *Registry) Action(id string) (*actionspec.Action, bool) {
	a, ok := r.actions[id]
	return a, ok
}

// ScriptInfo returns the cached script info for a script-kind action.
func (r *Registry) ScriptInfo(actionID string) (ScriptInfo, bool) {
	si, ok := r.scripts[actionID]
	return si, ok
}

// PackHash returns the content-addressable hash for a pack id, cached
// from load time (or the most recent SIGHUP reload).
func (r *Registry) PackHash(packID string) (string, bool) {
	h, ok := r.packHashes[packID]
	return h, ok
}

// RecomputePackHash re-reads the pack's files fresh from disk and
// returns the hash for the current bytes. Same algorithm as the load-
// time hash. Used by the dispatch path to detect post-load tampering
// (the cached `PackHash` was computed when the pack was last loaded /
// SIGHUP'd; this asks "what's the hash *right now*?"). The set of
// relpaths the rehash walks is the same set we computed at load time;
// added files between then and now don't change the hash, but that's
// the same boundary the cloud's trust pin is drawn against.
func (r *Registry) RecomputePackHash(packID string) (string, error) {
	pack, ok := r.packs[packID]
	if !ok {
		return "", fmt.Errorf("packs: pack %q not loaded", packID)
	}
	entries := r.packHashInputs[packID]
	if len(entries) == 0 {
		return "", fmt.Errorf("packs: no hash inputs cached for %q", packID)
	}

	fresh := make([]hashEntry, len(entries))
	for i, e := range entries {
		full := filepath.Join(pack.Root, e.rel)
		data, err := os.ReadFile(full)
		if err != nil {
			return "", fmt.Errorf("packs: rehash %s: %w", full, err)
		}
		fresh[i] = hashEntry{rel: e.rel, data: data}
	}
	return computePackHash(fresh), nil
}

// Packs returns all packs sorted by id.
func (r *Registry) Packs() []*packspec.Pack {
	out := make([]*packspec.Pack, 0, len(r.packs))
	for _, p := range r.packs {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Actions returns all actions sorted by id.
func (r *Registry) Actions() []*actionspec.Action {
	out := make([]*actionspec.Action, 0, len(r.actions))
	for _, a := range r.actions {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}
