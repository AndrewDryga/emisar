package main

import (
	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/selfupdate"
)

func updateCmd() *cobra.Command {
	var version string
	cmd := &cobra.Command{
		Use:   "update",
		Short: "Update this installer-managed runner",
		Long: `Update an official installer-managed runner to the latest stable release.

With GitHub CLI installed, the release checksum file is authenticated with its
Sigstore bundle; without it the command asks at a terminal, or warns and
continues unattended, on the checksum alone. The archive is checked against
that checksum before the bundled installer runs. The installer
preserves configuration, credentials, packs, and local evidence and rolls back
the installation when an update fails.

Container, copied, development, package-managed, and infrastructure-managed
binaries have no official installer receipt and are refused; update those from
their deployment source instead.`,
		Example: `  sudo emisar update
  sudo emisar update --version X.Y.Z`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return selfupdate.Run(cmd.Context(), selfupdate.Options{
				Version:        version,
				CurrentVersion: Version,
				Stdout:         cmd.OutOrStdout(),
				Stderr:         cmd.ErrOrStderr(),
				Stdin:          cmd.InOrStdin(),
				Interactive:    isTerminal(cmd.InOrStdin()),
			})
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "install an exact immutable runner version")
	return cmd
}
