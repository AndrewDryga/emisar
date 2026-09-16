//go:build linux

package validation

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// The runner's own /proc entry is a protected root too: environ there is
// runner.env and mem holds the bearer token. The canonical resolution every
// path arg goes through rewrites /proc/self into this very pid — the validator
// runs inside the runner — so a pack that named /proc/self/environ was pointed
// straight at the runner's secrets, whatever its own denylist said. Other pids
// stay exactly as readable as before.
func TestProtected_RefusesTheRunnersOwnProcEntry(t *testing.T) {
	self := filepath.Join("/proc", strconv.Itoa(os.Getpid()))
	schema := []actionspec.Arg{{
		Name:     "path",
		Type:     actionspec.ArgPath,
		Required: true,
		Validation: &actionspec.Validation{
			DeniedPrefixes: []string{"/etc/ssh"},
		},
	}}

	for _, target := range []string{
		"/proc/self/environ",
		"/proc/self/mem",
		"/proc/self/maps",
		filepath.Join(self, "environ"),
		filepath.Join(self, "cmdline"),
	} {
		_, err := Validate(schema, map[string]any{"path": target}, []string{self})
		if err == nil {
			t.Fatalf("%s must be refused: it resolves into the runner's own /proc entry", target)
		}
		assertProtected(t, err)
	}

	if _, err := Validate(schema, map[string]any{"path": "/proc/1/status"}, []string{self}); err != nil {
		t.Fatalf("another pid's entry must stay allowed, got %v", err)
	}
}
