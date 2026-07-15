package main

import (
	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

func stateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "state",
		Short: "Print the runner_state message this runner would advertise to cloud",
		RunE: func(_ *cobra.Command, _ []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			externalID, err := rt.ensureExternalID()
			if err != nil {
				return err
			}
			verifier, err := buildStateVerifier(rt.cfg, externalID)
			if err != nil {
				return err
			}
			b := &cloud.StateBuilder{
				AgentID:     externalID,
				Version:     Version,
				Group:       rt.cfg.Runner.Group,
				Labels:      rt.cfg.Runner.Labels,
				GetRegistry: rt.engine.Registry,
				Admission:   rt.admission,
				GetVerifier: func() *signing.Verifier { return verifier },
			}
			return printJSON(b.Build())
		},
	}
}
