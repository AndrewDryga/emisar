package main

import (
	"context"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
)

func actionCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "action", Short: "List, describe, and run actions locally"}
	cmd.AddCommand(actionListCmd())
	cmd.AddCommand(actionDescribeCmd())
	cmd.AddCommand(actionRunCmd())
	return cmd
}

func actionListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List loaded actions",
		RunE: func(_ *cobra.Command, _ []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			actions := rt.registry().Actions()
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
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			a, ok := rt.registry().Action(args[0])
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
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			if _, err := rt.ensureExternalID(); err != nil {
				return err
			}

			argMap, err := parseArgFlag(argList)
			if err != nil {
				return err
			}
			req := engine.Request{
				ActionID: args[0],
				Args:     argMap,
				Reason:   reason,
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
			res, err := rt.engine.Run(context.Background(), req)
			if err != nil {
				return err
			}
			return printJSON(res)
		},
	}
	cmd.Flags().StringArrayVar(&argList, "arg", nil, "argument as key=value (may repeat)")
	cmd.Flags().StringVar(&reason, "reason", "", "free-text reason recorded on the event")
	cmd.Flags().DurationVar(&timeout, "timeout", 0, "override timeout (clamped to action min/max)")
	cmd.Flags().BoolVar(&stream, "stream", false, "stream output to stdout/stderr as it arrives")
	return cmd
}
