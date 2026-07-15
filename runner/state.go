package main

import (
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
	return &cobra.Command{
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
}
