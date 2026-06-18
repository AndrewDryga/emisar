// Command emisar is the local enforcement runner for AI-safe infrastructure
// actions.
//
// emisar dials out to the control plane over a TLS websocket, receives
// named action commands, re-validates their arguments against locally
// declared schemas, executes via os/exec (argv-only — never a shell), and
// returns redacted streaming output to the cloud. Every attempt is also
// written to a local JSONL log on the host for forensics.
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var (
	flagConfig   string
	flagPacksDir []string
	flagJSONOut  bool
)

// Version is overridden via -ldflags at build time.
var Version = "0.4.0-dev"

func main() {
	root := &cobra.Command{
		Use:   "emisar",
		Short: "Local enforcement runner for AI-safe infrastructure actions",
		Long: `emisar is the local enforcement layer for LLM-driven infrastructure
operations. Commands arrive from a control plane over an outbound websocket;
the runner re-validates, executes, redacts, and journals locally. Policy
authoring, approval workflow, and audit storage live in the cloud.`,
		// SilenceErrors: main prints the error itself (below); without this
		// cobra prints it too, so a failing command shows the error twice.
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       Version,
	}
	root.PersistentFlags().StringVar(&flagConfig, "config", "", "path to config.yaml (default: $EMISAR_CONFIG, else /etc/emisar/config.yaml)")
	root.PersistentFlags().StringSliceVar(&flagPacksDir, "packs-dir", nil, "extra pack search dirs (overrides config)")
	root.PersistentFlags().BoolVar(&flagJSONOut, "json", false, "emit JSON output where applicable")

	root.AddCommand(connectCmd())
	root.AddCommand(packCmd())
	root.AddCommand(actionCmd())
	root.AddCommand(stateCmd())
	root.AddCommand(doctorCmd())
	root.AddCommand(eventsCmd())
	root.AddCommand(auditCmd())
	root.AddCommand(keygenCmd())
	root.AddCommand(versionCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
