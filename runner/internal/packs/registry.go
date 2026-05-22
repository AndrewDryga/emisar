package packs

import (
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

// PackHash returns the content-addressable hash for a pack id.
func (r *Registry) PackHash(packID string) (string, bool) {
	h, ok := r.packHashes[packID]
	return h, ok
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
