package main

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

// State advertises signing policy, not the runner target reference. Before the
// first connect, this fixed non-secret identity lets the verifier validate that
// policy without creating durable runtime state.
const statePreviewExternalID = "00000000-0000-4000-8000-000000000000"

func stateCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Print the runner_state message this runner would advertise to cloud",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			registry, _, err := loadRegistry(cfg)
			if err != nil {
				return err
			}
			policy, err := admission.New(cfg.Admission.Allow, cfg.Admission.Deny, cfg.Admission.MaxRisk)
			if err != nil {
				return err
			}
			externalID, found, err := existingExternalID(cfg.Runner.ID, cfg.Paths.DataDir)
			if err != nil {
				return err
			}
			if !found {
				externalID = statePreviewExternalID
			}
			verifier, err := buildStateVerifier(cfg, externalID)
			if err != nil {
				return err
			}
			b := &cloud.StateBuilder{
				Version:     Version,
				Group:       cfg.Runner.Group,
				Labels:      cfg.Runner.Labels,
				GetRegistry: func() *packs.Registry { return registry },
				Admission:   policy,
				GetVerifier: func() *signing.Verifier { return verifier },
			}
			return printJSON(b.Build())
		},
	}
	cmd.AddCommand(stateCheckDispatchLogCmd())
	return cmd
}

// stateCheckDispatchLogCmd verifies the durable dispatch log loads — the
// installer runs it with the STAGED binary before activating an upgrade, so a
// corrupt log is caught (with options presented) instead of leaving the new
// runner refusing to start.
func stateCheckDispatchLogCmd() *cobra.Command {
	var dataDir string
	cmd := &cobra.Command{
		Use:   "check-dispatch-log",
		Short: "Verify the durable dispatch log loads; exit nonzero if it is corrupt",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if dataDir == "" {
				cfg, err := loadConfig()
				if err != nil {
					return err
				}
				dataDir = cfg.Paths.DataDir
			}
			report := cloud.InspectDispatchLog(dataDir)
			switch report.State {
			case cloud.DispatchLogCorrupt:
				return fmt.Errorf(
					"dispatch log %s is unreadable: %v\nquarantine it to start a clean log: mv %s %s.corrupt",
					report.Path, report.Err, report.Path, report.Path)
			case cloud.DispatchLogLegacy:
				fmt.Fprintf(cmd.OutOrStdout(),
					"ok: %d entries at %s (pre-v0.12 state; connect migrates it forward)\n",
					report.Entries, report.Path)
			case cloud.DispatchLogAbsent:
				fmt.Fprintln(cmd.OutOrStdout(), "ok: no dispatch log yet")
			default:
				fmt.Fprintf(cmd.OutOrStdout(), "ok: %d entries at %s\n", report.Entries, report.Path)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&dataDir, "data-dir", "",
		"runner data directory holding the dispatch log (default: from config)")
	return cmd
}
