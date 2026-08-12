// Command emisar is the local enforcement runner for AI-safe infrastructure
// actions.
//
// emisar dials out to the control plane over a TLS websocket, receives
// named action commands, enforces local trust and argument contracts, executes
// only installed action definitions, and returns redacted streaming output.
// Every attempt is also written to a local JSONL log for on-host forensics.
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

// jsonOutputAnnotation marks a command whose output --json actually changes.
// Set it with emitsJSON() at the point the command is built, so adding a JSON
// branch and declaring it are the same edit.
const jsonOutputAnnotation = "emisar.json_output"

// emitsJSON declares that cmd honors --json.
func emitsJSON(cmd *cobra.Command) *cobra.Command {
	if cmd.Annotations == nil {
		cmd.Annotations = map[string]string{}
	}
	cmd.Annotations[jsonOutputAnnotation] = "yes"
	return cmd
}

// Version is overridden via -ldflags at build time.
var Version = "dev"

func main() {
	root := &cobra.Command{
		Use:   "emisar",
		Short: "Local enforcement runner for AI-safe infrastructure actions",
		Long: `emisar is the local enforcement layer for LLM-driven infrastructure
operations. Commands arrive from a control plane over an outbound websocket;
the runner re-validates, executes, redacts, and journals locally. Policy
authoring, approval workflow, and audit storage live in the cloud.`,
		Example: `  # Serve the control plane (the long-running daemon)
  emisar connect

  # Run a read-only action locally against this host
  emisar action run linux.uptime --reason "check load"

  # Validate a pack before trusting it
  emisar pack validate ./packs/linux-core

  # Set up bridge-attested (signed) dispatch in one shot
  emisar signing init`,
		// SilenceErrors: main prints the error itself (below); without this
		// cobra prints it too, so a failing command shows the error twice.
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       Version,
	}
	root.PersistentFlags().StringVar(&flagConfig, "config", "", "path to config.yaml (default: $EMISAR_CONFIG, else /etc/emisar/config.yaml)")
	root.PersistentFlags().StringSliceVar(&flagPacksDir, "packs-dir", nil, "extra pack search dirs (overrides config)")
	root.PersistentFlags().BoolVar(&flagJSONOut, "json", false, "emit JSON output where applicable")

	// --json is persistent so it can precede the subcommand, which means cobra
	// accepts it everywhere — including on commands that emit no JSON at all.
	// Refuse there instead of ignoring it: a `| jq` pipeline that silently gets
	// human text is worse than one that fails, and this class already shipped
	// once (see the note in packValidateCmd).
	root.PersistentPreRunE = func(cmd *cobra.Command, _ []string) error {
		if cmd.Flags().Changed("json") && cmd.Annotations[jsonOutputAnnotation] == "" {
			return fmt.Errorf("%s does not emit JSON; --json is not supported here", cmd.CommandPath())
		}
		return nil
	}

	// Command groups so `emisar --help` reads by category, not one flat wall.
	root.AddGroup(
		&cobra.Group{ID: "serve", Title: "Serve:"},
		&cobra.Group{ID: "actions", Title: "Actions & packs:"},
		&cobra.Group{ID: "diag", Title: "Diagnose & audit:"},
		&cobra.Group{ID: "maintain", Title: "Maintain:"},
		&cobra.Group{ID: "signing", Title: "Signed dispatch:"},
	)
	add := func(groupID string, c *cobra.Command) {
		c.GroupID = groupID
		root.AddCommand(c)
	}
	add("serve", connectCmd())
	add("actions", actionCmd())
	add("actions", packCmd())
	add("diag", emitsJSON(doctorCmd()))
	add("diag", stateCmd())
	add("diag", eventsCmd())
	add("diag", auditCmd())
	add("maintain", updateCmd())
	add("signing", signingCmd())
	// version + the built-in help/completion stay ungrouped ("Additional Commands").
	root.AddCommand(emitsJSON(versionCmd()))

	// The default help plus a Paths footer on the ROOT help only, so `emisar`
	// on a fresh host says where its config, packs, token, and logs live.
	defaultHelp := root.HelpFunc()
	root.SetHelpFunc(func(cmd *cobra.Command, args []string) {
		defaultHelp(cmd, args)
		if cmd == root {
			writePaths(cmd.OutOrStdout())
		}
	})

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// showHelp is the RunE every command group carries. Cobra short-circuits a
// command with no Run/RunE straight to help — before its Args validator runs —
// so a group without one answers `emisar pack lst` with usage and exit 0, and a
// typo reads as success. With this RunE plus `Args: cobra.NoArgs`, bare
// `emisar pack` still prints help while a stray operand is rejected.
func showHelp(cmd *cobra.Command, _ []string) error { return cmd.Help() }

// requireOne is cobra.ExactArgs(1) that names the command's own placeholder
// when nothing was passed: "accepts 1 arg(s), received 0" tells an operator how
// many, never which.
func requireOne(placeholder string) cobra.PositionalArgs {
	return func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return fmt.Errorf("%s requires %s", cmd.CommandPath(), placeholder)
		}
		return cobra.ExactArgs(1)(cmd, args)
	}
}
