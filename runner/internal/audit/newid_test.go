package audit

import (
	"strings"
	"testing"
	"time"
)

// NewID was the runner module's only use of github.com/oklog/ulid/v2, for one
// expression. This module is CLIENT-SHIPPED — self-hosters build it and audit
// its go.sum — so a dependency carried for one line is their supply-chain
// surface. These pin the layout the hand-rolled version has to keep.
func TestNewID(t *testing.T) {
	const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

	t.Run("26 Crockford characters, no ambiguous letters", func(t *testing.T) {
		id := NewID("")
		if len(id) != 26 {
			t.Fatalf("len = %d, want 26: %q", len(id), id)
		}
		for _, r := range id {
			if !strings.ContainsRune(alphabet, r) {
				t.Errorf("character %q is outside Crockford base32: %q", r, id)
			}
		}
		// I, L, O and U are excluded precisely so a transcribed id cannot be
		// misread as 1, 0 or V.
		if strings.ContainsAny(id, "ILOU") {
			t.Errorf("id contains an ambiguous letter: %q", id)
		}
	})

	t.Run("the prefix is joined with an underscore", func(t *testing.T) {
		id := NewID("evt")
		if !strings.HasPrefix(id, "evt_") {
			t.Fatalf("id = %q, want an evt_ prefix", id)
		}
		if len(id) != len("evt_")+26 {
			t.Errorf("prefixed len = %d, want %d", len(id), len("evt_")+26)
		}
	})

	// A journal id that sorts by creation time is the reason the ULID layout is
	// kept rather than replaced with plain random bytes.
	t.Run("later ids sort after earlier ones", func(t *testing.T) {
		first := NewID("")
		time.Sleep(2 * time.Millisecond)
		second := NewID("")
		if !(first < second) {
			t.Errorf("ids do not sort by time: %q then %q", first, second)
		}
	})

	// These address lines in an append-only security journal; a collision would
	// let one event be mistaken for another.
	t.Run("ids are unique", func(t *testing.T) {
		seen := make(map[string]bool, 2000)
		for i := 0; i < 2000; i++ {
			id := NewID("evt")
			if seen[id] {
				t.Fatalf("duplicate id after %d draws: %q", i, id)
			}
			seen[id] = true
		}
	})
}
