// Command emisar is the local enforcement runner for AI-safe infrastructure
// actions.
//
// emisar dials out to the control plane over a TLS websocket, receives
// named action commands, enforces local trust and argument contracts, executes
// only installed action definitions, and returns redacted streaming output.
// Every attempt is also written to a local JSONL log for on-host forensics.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

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
	// One process-lifetime signal context: Ctrl-C / SIGTERM cancel every
	// command's cmd.Context(), so a long local action's process group is
	// terminated through the engine's grace path instead of being orphaned
	// (Darwin has no Pdeathsig safety net). connect layers SIGHUP on top.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := newRootCmd().ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(exitCode(ctx, usageErrorFromExecute(err)))
	}
}

// Exit codes, matching the bridge's frozen contract: usage failures are 2,
// everything else is 1, and an interrupt is 130.
//
// The runner used to answer 1 for all of them — a mistyped flag, a
// misconfigured host, and an action that ran and failed were indistinguishable
// to a script, while emisar-mcp answered 2 for the very same mistakes. That
// matters because `action run` is the documented post-install verification
// step, so CI really does branch on it. compatibility.md freezes the bridge's
// codes explicitly and said nothing about the runner's, which means the flat 1
// would have frozen by default.
const (
	exitFailure = 1
	exitUsage   = 2
	exitSignal  = 130
)

// usageError marks a mistake in how the command was INVOKED, as opposed to a
// failure of the work it went on to do.
type usageError struct{ err error }

func (e usageError) Error() string { return e.err.Error() }
func (e usageError) Unwrap() error { return e.err }

// usageErrorFromExecute recognises the invocation mistakes cobra reports as
// plain errors rather than through SetFlagErrorFunc. Matching its message text
// is unpleasant but it is the only signal cobra gives, and the alternative —
// treating "you typed it wrong" as "the work failed" — is what shipped.
func usageErrorFromExecute(err error) error {
	var usage usageError
	if errors.As(err, &usage) {
		return err
	}
	for _, prefix := range []string{
		"unknown command",
		"unknown flag",
		"unknown shorthand flag",
		"accepts ",
		"requires at least",
		"requires exactly",
	} {
		if strings.HasPrefix(err.Error(), prefix) {
			return usageError{err}
		}
	}
	return err
}

func exitCode(ctx context.Context, err error) int {
	var usage usageError
	if errors.As(err, &usage) {
		return exitUsage
	}
	// Ctrl-C during the work, not a failure of it. Checked after usage so an
	// interrupt arriving while a usage error surfaces still reports the usage
	// mistake, which is the actionable one.
	if ctx.Err() != nil && errors.Is(ctx.Err(), context.Canceled) {
		return exitSignal
	}
	return exitFailure
}

// newRootCmd builds the full command tree. Split from main so tests can walk
// the real surface (the CLI-surface golden) without re-exec.
func newRootCmd() *cobra.Command {
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
	// Every way cobra can tell us the INVOCATION was wrong, marked so main can
	// exit 2 instead of the flat 1 that made a typo indistinguishable from a
	// broken host. A bad flag comes through here; a bad command or a bad
	// argument count arrives as an ordinary error from Execute, so those are
	// recognised by cobra's own message prefixes in usageErrorFromExecute.
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		return usageError{err}
	})
	root.PersistentFlags().StringVar(&flagConfig, "config", "", "path to config.yaml (default: $EMISAR_CONFIG, else /etc/emisar/config.yaml)")
	// "extra ... dirs" was wrong twice: it REPLACES the configured list rather
	// than extending it, and it is not only a search path — `pack install`
	// writes into its first entry and `pack uninstall` does a recursive delete
	// under it. A flag whose help says "search" while it names the delete
	// target is the safer-sounding of the two spellings, and `--dest` already
	// exists for the write path.
	root.PersistentFlags().StringSliceVar(&flagPacksDir, "packs-dir", nil,
		"pack dirs to use instead of the configured ones; also the install/uninstall target when --dest is absent")
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
	add("diag", emitsJSON(statusCmd()))
	// These emit nothing BUT JSON — state and action describe print one
	// document, the events readers stream JSONL — yet they refused --json while
	// root help advertised it as a global flag on every command. A `| jq`
	// pipeline that has to know which JSON-only commands reject the JSON flag is
	// the opposite of the annotation's purpose. Accepting it is a no-op here,
	// which is exactly right: it states what the command already does.
	add("diag", emitsJSON(stateCmd()))
	add("diag", emitsJSON(eventsCmd()))
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

	return root
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
		// Marked at the source: this is an invocation mistake, so it exits 2.
		// Recognising it by message text instead would mean matching our own
		// prose, which is exactly the fragile thing usageErrorFromExecute only
		// does because cobra gives no other signal.
		if len(args) == 0 {
			return usageError{fmt.Errorf("%s requires %s", cmd.CommandPath(), placeholder)}
		}
		if err := cobra.ExactArgs(1)(cmd, args); err != nil {
			return usageError{err}
		}
		return nil
	}
}
