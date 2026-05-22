package main

import (
	"fmt"
	goruntime "runtime"
	"runtime/debug"

	"github.com/spf13/cobra"
)

// versionCmd prints build and runtime metadata. Useful in deployment
// pipelines and when debugging: a one-line answer to "what version is
// this host running, exactly?"
func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the runner version and build info",
		RunE: func(_ *cobra.Command, _ []string) error {
			fmt.Printf("emisar %s\n", Version)
			fmt.Printf("  go: %s %s/%s\n", goruntime.Version(), goruntime.GOOS, goruntime.GOARCH)
			// VCS info is populated by the Go toolchain when building from
			// a git checkout — useful for spotting "is this binary built
			// from a tagged release or from someone's local branch?"
			if info, ok := debug.ReadBuildInfo(); ok {
				for _, s := range info.Settings {
					switch s.Key {
					case "vcs.revision":
						fmt.Printf("  commit: %s\n", s.Value)
					case "vcs.time":
						fmt.Printf("  built: %s\n", s.Value)
					case "vcs.modified":
						if s.Value == "true" {
							fmt.Printf("  vcs: dirty (uncommitted changes)\n")
						}
					}
				}
			}
			return nil
		},
	}
}
