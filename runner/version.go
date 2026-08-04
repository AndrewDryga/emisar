package main

import (
	"fmt"
	"io"
	"os"
	goruntime "runtime"
	"runtime/debug"

	"github.com/spf13/cobra"
)

// versionInfo is the build and runtime metadata `version` reports. Both the
// human lines and the --json payload render from this one value, so a fleet
// script and an operator can never see different facts about the same binary.
//
// The VCS fields are populated by the Go toolchain only when building from a
// git checkout — useful for spotting "is this binary built from a tagged
// release or from someone's local branch?" — and are omitted otherwise.
type versionInfo struct {
	Version string `json:"version"`
	Go      string `json:"go"`
	OS      string `json:"os"`
	Arch    string `json:"arch"`
	Commit  string `json:"commit,omitempty"`
	BuiltAt string `json:"built_at,omitempty"`
	Dirty   bool   `json:"dirty,omitempty"`
}

// versionCmd prints build and runtime metadata. Useful in deployment
// pipelines and when debugging: a one-line answer to "what version is
// this host running, exactly?"
func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the runner version and build info",
		RunE: func(_ *cobra.Command, _ []string) error {
			info := gatherVersionInfo()
			if flagJSONOut {
				return printJSON(info)
			}
			writeVersion(os.Stdout, info)
			return nil
		},
	}
}

func gatherVersionInfo() versionInfo {
	info := versionInfo{
		Version: Version,
		Go:      goruntime.Version(),
		OS:      goruntime.GOOS,
		Arch:    goruntime.GOARCH,
	}
	build, ok := debug.ReadBuildInfo()
	if !ok {
		return info
	}
	for _, s := range build.Settings {
		switch s.Key {
		case "vcs.revision":
			info.Commit = s.Value
		case "vcs.time":
			info.BuiltAt = s.Value
		case "vcs.modified":
			info.Dirty = s.Value == "true"
		}
	}
	return info
}

func writeVersion(w io.Writer, info versionInfo) {
	fmt.Fprintf(w, "emisar %s\n", info.Version)
	fmt.Fprintf(w, "  go: %s %s/%s\n", info.Go, info.OS, info.Arch)
	if info.Commit != "" {
		fmt.Fprintf(w, "  commit: %s\n", info.Commit)
	}
	if info.BuiltAt != "" {
		fmt.Fprintf(w, "  built: %s\n", info.BuiltAt)
	}
	if info.Dirty {
		fmt.Fprintf(w, "  vcs: dirty (uncommitted changes)\n")
	}
}
