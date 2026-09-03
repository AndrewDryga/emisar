package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

func stateCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Print the runner_state message this runner would advertise to the control plane",
		Long: `Render the runner_state message locally — the same catalog, admission
policy, and signing trust the daemon would advertise — without connecting
to the control plane or touching a live session.

Use it to preview what a config or pack change will publish before
starting the runner, and to diff two hosts that should look identical.`,
		Args: cobra.NoArgs,
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
			identity, err := configIdentity(cfg)
			if err != nil {
				return err
			}
			verifier, err := buildStateVerifier(cfg, identity)
			if err != nil {
				return err
			}
			b := &cloud.StateBuilder{
				Version:      Version,
				Group:        cfg.Runner.Group,
				Labels:       cfg.Runner.Labels,
				GetRegistry:  func() *packs.Registry { return registry },
				GetAdmission: func() *admission.Policy { return policy },
				GetVerifier:  func() *signing.Verifier { return verifier },
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
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if dataDir != "" && (flagConfig != "" || os.Getenv("EMISAR_CONFIG") != "") {
				cfg, err := loadConfig()
				if err != nil {
					return err
				}
				if filepath.Clean(cfg.Paths.DataDir) != filepath.Clean(dataDir) {
					return fmt.Errorf(
						"explicit data directory %s does not match configured paths.data_dir %s",
						dataDir, cfg.Paths.DataDir)
				}
			} else if dataDir == "" {
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
					"dispatch log %s is unreadable: %v\nrecovery: %s\nwarning: quarantining forgets replay history and may allow a redelivered action to run again",
					report.Path, report.Err, cloud.DispatchLogQuarantineGuidance(dataDir))
			case cloud.DispatchLogLegacy:
				fmt.Fprintf(cmd.OutOrStdout(),
					"ok: %d entries at %s (older dispatch state; connect migrates it forward)\n",
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
