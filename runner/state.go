package main

import (
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
	return cmd
}
