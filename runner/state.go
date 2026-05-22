package main

import (
	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
)

func stateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "state",
		Short: "Print the agent_state message this runner would advertise to cloud",
		RunE: func(_ *cobra.Command, _ []string) error {
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()
			b := &cloud.StateBuilder{
				AgentID:     rt.cfg.Runner.ID,
				Version:     Version,
				Group:       rt.cfg.Runner.Group,
				Labels:      rt.cfg.Runner.Labels,
				GetRegistry: rt.engine.Registry,
			}
			return printJSON(b.Build())
		},
	}
}
