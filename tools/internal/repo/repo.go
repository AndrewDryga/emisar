// Package repo locates the repository root for tools that read committed
// files by repo-relative path regardless of the invoking directory.
package repo

import (
	"fmt"
	"os/exec"
	"strings"
)

// Root returns the git worktree root of the current directory.
func Root() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("resolving repo root: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}
