package main

import (
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
)

func actionCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "action",
		Aliases: []string{"actions"},
		Short:   "List, describe, and run actions locally",
		Args:    cobra.NoArgs,
		RunE:    showHelp,
	}
	cmd.AddCommand(emitsJSON(actionListCmd()))
	cmd.AddCommand(actionDescribeCmd())
	cmd.AddCommand(actionRunCmd())
	return cmd
}

func actionListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List loaded actions",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			registry, _, err := loadRegistry(cfg)
			if err != nil {
				return err
			}
			actions := registry.Actions()
			if flagJSONOut {
				return printJSON(actions)
			}
			tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tPACK\tKIND\tRISK\tTITLE")
			for _, a := range actions {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n",
					a.ID, a.PackID, a.Kind, a.Risk, a.Title)
			}
			return tw.Flush()
		},
	}
}

func actionDescribeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "describe <action-id>",
		Short: "Print full action definition",
		Args:  requireOne("<action-id>"),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			registry, _, err := loadRegistry(cfg)
			if err != nil {
				return err
			}
			a, ok := registry.Action(args[0])
			if !ok {
				return fmt.Errorf("unknown action: %s", args[0])
			}
			return printJSON(a)
		},
	}
}

func actionRunCmd() *cobra.Command {
	var (
		argList []string
		reason  string
		timeout time.Duration
		stream  bool
	)
	cmd := &cobra.Command{
		Use:   "run <action-id>",
		Short: "Run an action locally (bypasses cloud — for debugging packs)",
		Args:  requireOne("<action-id>"),
		RunE: func(cmd *cobra.Command, args []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()

			argMap, err := parseArgFlag(argList)
			if err != nil {
				return err
			}
			req := engine.Request{
				ActionID: args[0],
				Args:     argMap,
				Reason:   reason,
			}
			// A negative or zero --timeout used to fall through to the action's
			// default and exit 0, so `--timeout=-5s` looked accepted and ran with
			// a limit the operator never chose. Say so instead.
			if timeout < 0 {
				return fmt.Errorf("--timeout must be positive (got %s)", timeout)
			}
			if timeout > 0 {
				req.Opts.Timeout = timeout
			}
			if stream {
				req.OnProgress = func(s executor.Stream, line []byte) {
					if s == executor.StreamStderr {
						os.Stderr.Write(line)
					} else {
						os.Stdout.Write(line)
					}
				}
			}
			res, err := rt.engine.Run(cmd.Context(), req)
			if err != nil {
				return err
			}
			if err := printJSON(res); err != nil {
				return err
			}
			// `emisar pack info` tells operators to run this as the "verify it
			// works" step, so a failed, timed-out, or refused action must not
			// exit 0 — a script or installer could never detect it. The JSON is
			// already on stdout; the exit code carries the outcome, as it does
			// for `doctor`.
			if res.Status != engine.StatusSuccess {
				return fmt.Errorf("action %s finished %s", args[0], res.Status)
			}
			return nil
		},
	}
	cmd.Flags().StringArrayVar(&argList, "arg", nil, "argument as key=value (may repeat)")
	cmd.Flags().StringVar(&reason, "reason", "", "free-text reason recorded on the event")
	cmd.Flags().DurationVar(&timeout, "timeout", 0, "override timeout (clamped to action min/max)")
	cmd.Flags().BoolVar(&stream, "stream", false, "stream output to stdout/stderr as it arrives")
	return cmd
}
