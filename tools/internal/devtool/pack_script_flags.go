package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// A packaged script that does not set -e keeps going after a failed step and
// exits 0 on whatever the last command printed, which the runner reports as a
// successful action. That is the shape the catalog must not ship: an operator
// approved a mutation, a step failed silently, and the run says it worked.
// `-u` is the same story for a missing credential — an unset token becomes an
// empty header rather than an error.
//
// The floor is per interpreter: `pipefail` is a bash builtin, so a /bin/sh
// script cannot carry it, and busybox ash would fail to start. Nine scripts
// had drifted below the floor — five with no flags at all and four with only
// `-u`, including the one multi-step script in the catalog.
var packScriptFlagFloor = map[string][]string{
	"/bin/sh":   {"set -eu"},
	"/bin/bash": {"set -euo pipefail"},
}

func validatePackScriptFlags(input packActionLintInput) error {
	scripts, err := packScriptRefs(input)
	if err != nil {
		return err
	}
	refs := make([]packScriptRef, 0, len(scripts))
	for ref := range scripts {
		refs = append(refs, ref)
	}
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].path != refs[j].path {
			return refs[i].path < refs[j].path
		}
		return refs[i].interpreter < refs[j].interpreter
	})

	var failures []string
	for _, ref := range refs {
		want, ok := packScriptFlagFloor[ref.interpreter]
		if !ok {
			continue
		}
		data, err := os.ReadFile(filepath.Join(input.packDir, ref.path))
		if err != nil {
			return err
		}
		if packScriptSetsFlags(string(data), want) {
			continue
		}
		failures = append(failures, fmt.Sprintf("%s (%s): expected %q",
			ref.path, packScriptActionContext(scripts[ref]), want[0]))
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"packaged scripts set the failure floor before their first command: %s",
			strings.Join(failures, "; "),
		)
	}
	return nil
}

// packScriptSetsFlags looks for the floor line before anything that executes,
// because `set -eu` after the first command leaves that command unguarded.
func packScriptSetsFlags(script string, want []string) bool {
	for _, line := range strings.Split(script, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		for _, accepted := range want {
			if line == accepted {
				return true
			}
		}
		return false
	}
	return false
}
