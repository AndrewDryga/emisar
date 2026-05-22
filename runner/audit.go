package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/spf13/cobra"
)

func auditCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "audit",
		Short: "Audit trail tools (chain verification, etc.)",
		Long: `The local JSONL audit trail is a SHA-256-chained sequence: each event
carries the hash of the previous serialized line. Tampering with any
line invalidates every subsequent event, which 'emisar audit verify'
detects.`,
	}
	cmd.AddCommand(auditVerifyCmd())
	return cmd
}

func auditVerifyCmd() *cobra.Command {
	var all bool
	cmd := &cobra.Command{
		Use:   "verify [path]",
		Short: "Re-derive the hash chain of a JSONL audit log and report breaks",
		Long: `Walks the JSONL log line by line, recomputing the expected prev_hash
from each preceding line. Exits 0 if every entry chains correctly; exits
1 (with line + event_id) on the first break.

With no path, verifies the configured events.jsonl from the agent's
config. Pass a path to verify a specific (or rotated) file:

    emisar audit verify /var/log/emisar/events.jsonl
    emisar audit verify /var/log/emisar/events.jsonl.1

Pass --all to walk every rotated sibling (.1, .2, ...) in the same
directory in oldest-first order. Each file's chain is verified
independently (the chain is per-file: rotation breaks it by design).`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			path, err := resolveAuditPath(args)
			if err != nil {
				return err
			}
			paths := []string{path}
			if all {
				paths, err = discoverRotated(path)
				if err != nil {
					return err
				}
			}

			var firstBreak error
			for _, p := range paths {
				if err := audit.VerifyChain(p); err == nil {
					fmt.Fprintf(os.Stdout, "audit: chain intact: %s\n", p)
				} else {
					var ve *audit.VerifyError
					if errors.As(err, &ve) {
						fmt.Fprintf(os.Stderr, "audit: %s: %s\n", p, ve.Error())
						if firstBreak == nil {
							firstBreak = err
						}
					} else {
						return err
					}
				}
			}
			if firstBreak != nil {
				os.Exit(1)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&all, "all", false, "verify the active file plus every rotated .N sibling")
	return cmd
}

// discoverRotated returns the active path plus every .1 / .2 / ...
// sibling in the same directory, sorted oldest-first (highest N first,
// then the active file). The chain is per-file by design — rotation
// snaps it — so each is verified independently. Returning oldest-first
// matches the order an operator reads them for forensic walking.
func discoverRotated(active string) ([]string, error) {
	dir := filepath.Dir(active)
	base := filepath.Base(active)

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read dir %s: %w", dir, err)
	}

	rotated := make([]struct {
		path string
		idx  int
	}, 0)

	prefix := base + "."
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		idx, err := strconv.Atoi(strings.TrimPrefix(name, prefix))
		if err != nil {
			continue
		}
		rotated = append(rotated, struct {
			path string
			idx  int
		}{filepath.Join(dir, name), idx})
	}

	sort.Slice(rotated, func(i, j int) bool { return rotated[i].idx > rotated[j].idx })

	out := make([]string, 0, len(rotated)+1)
	for _, r := range rotated {
		out = append(out, r.path)
	}
	out = append(out, active)
	return out, nil
}

func resolveAuditPath(args []string) (string, error) {
	if len(args) == 1 {
		return args[0], nil
	}
	rt, err := boot()
	if err != nil {
		return "", err
	}
	return rt.cfg.Events.JSONLPath, nil
}
