package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var updateCLISurface = flag.Bool("update-cli-surface", false, "update the CLI surface golden")

// TestCLISurfaceGolden pins the public command tree: every visible command
// path with its flag names. This surface freezes at 1.0 — the golden is the
// mechanical mirror of the verb/flag inventory in
// .agent/kb/specs/compatibility.md, so a new, renamed, or removed verb or
// flag cannot ship outside the compatibility review unnoticed.
//
// On a deliberate surface change: regenerate with
// `go test -run TestCLISurfaceGolden -update-cli-surface .` and update the
// compatibility inventory in the same change.
func TestCLISurfaceGolden(t *testing.T) {
	root := newRootCmd()
	// Execute() normally installs these; walking the tree directly needs them
	// added explicitly so the golden carries the complete public surface.
	root.InitDefaultHelpCmd()
	root.InitDefaultCompletionCmd()

	var b strings.Builder
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		if c.Hidden {
			return
		}
		line := c.CommandPath()
		c.LocalFlags().VisitAll(func(f *pflag.Flag) {
			if f.Hidden {
				return
			}
			line += " --" + f.Name
		})
		b.WriteString(line + "\n")
		for _, sub := range c.Commands() {
			walk(sub)
		}
	}
	walk(root)

	path := filepath.Join("testdata", "cli_surface.golden")
	if *updateCLISurface {
		if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v (regenerate with -update-cli-surface)", err)
	}
	if string(want) != b.String() {
		t.Fatalf("the public CLI surface changed — this is a v1 compatibility surface.\n"+
			"If deliberate, regenerate with -update-cli-surface AND update the verb/flag\n"+
			"inventory in .agent/kb/specs/compatibility.md in the same change.\n%s",
			surfaceDiff(string(want), b.String()))
	}
}

func surfaceDiff(want, got string) string {
	wantSet := map[string]bool{}
	for _, l := range strings.Split(strings.TrimSpace(want), "\n") {
		wantSet[l] = true
	}
	gotSet := map[string]bool{}
	for _, l := range strings.Split(strings.TrimSpace(got), "\n") {
		gotSet[l] = true
	}
	var b strings.Builder
	for _, l := range strings.Split(strings.TrimSpace(want), "\n") {
		if !gotSet[l] {
			fmt.Fprintf(&b, "- %s\n", l)
		}
	}
	for _, l := range strings.Split(strings.TrimSpace(got), "\n") {
		if !wantSet[l] {
			fmt.Fprintf(&b, "+ %s\n", l)
		}
	}
	return b.String()
}
