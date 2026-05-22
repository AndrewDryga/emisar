package main

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

func packCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "pack", Short: "Manage action packs"}
	cmd.AddCommand(packListCmd())
	cmd.AddCommand(packValidateCmd())
	return cmd
}

func packListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List installed packs",
		RunE: func(cmd *cobra.Command, _ []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			ps := rt.registry().Packs()
			if flagJSONOut {
				return printJSON(ps)
			}
			tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tVERSION\tACTIONS\tHASH\tDESCRIPTION")
			for _, p := range ps {
				actions := 0
				for _, a := range rt.registry().Actions() {
					if a.PackID == p.ID {
						actions++
					}
				}
				hash, _ := rt.registry().PackHash(p.ID)
				fmt.Fprintf(tw, "%s\t%s\t%d\t%s\t%s\n", p.ID, p.Version, actions, shortHash(hash), p.Description)
			}
			return tw.Flush()
		},
	}
}

func packValidateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate <path>",
		Short: "Validate a pack on disk without loading it into the runner",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := packs.LoadOne(args[0], packs.LoadOptions{})
			if err != nil {
				return err
			}
			fmt.Printf("pack %s OK: %d actions\n",
				reg.Packs()[0].ID, len(reg.Actions()))
			return nil
		},
	}
}

func shortHash(h string) string {
	const prefix = "sha256:"
	if len(h) > len(prefix)+12 {
		return h[:len(prefix)+12]
	}
	return h
}
