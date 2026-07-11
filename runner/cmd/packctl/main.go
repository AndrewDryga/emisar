// Command packctl is the maintainer/publisher tool for the emisar pack
// registry: it builds the versioned artifact tree from a packs directory and
// publishes it to the public GCS bucket.
//
// It deliberately lives in the SAME Go module as the runner so the published
// pack content hash is produced by the exact loader the runner enforces at
// load time (internal/packs LoadAll/PackHash) — never a reimplementation. It
// is NOT an on-host tool: the emisar host binary ships operator verbs only,
// so publisher tooling and the linked internal/catalog surface stay out of it.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// flagJSONOut mirrors the emisar CLI's persistent --json flag: subcommands
// print machine-readable output (the build manifest, the publish result) when
// it is set. It lives on the root's persistent flags; commands read this global.
var flagJSONOut bool

// Version is overridden via -ldflags at build time.
var Version = "0.4.0-dev"

func main() {
	root := &cobra.Command{
		Use:   "packctl",
		Short: "Maintainer tooling for the emisar pack registry",
		Long: `packctl builds and publishes the versioned pack-registry artifacts.

It is maintainer/publisher tooling, not an on-host runner command — the emisar
host binary carries operator verbs only. packctl shares the runner's module so
the published pack content hash is computed by the same loader the runner uses
at load time, matching 'emisar pack validate' byte-for-byte.`,
		// SilenceErrors: main prints the error itself (below); without this
		// cobra prints it too, so a failing command shows the error twice.
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       Version,
	}
	root.PersistentFlags().BoolVar(&flagJSONOut, "json", false, "emit JSON output where applicable")

	root.AddCommand(packCatalogCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func banner(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}
