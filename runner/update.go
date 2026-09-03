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

For runner 0.23.1 and newer, the release checksum is authenticated from a
downloaded Sigstore bundle with GitHub CLI; a GitHub login is not required, but
a fresh verifier must reach the public Sigstore trust-root services. The archive
is checked against that authenticated metadata. Older releases require an
authenticated GitHub CLI and online archive provenance instead. Runner 0.22.1
is the only accepted pre-bundle rollback target; earlier tags have no accepted
pinned legacy workflow identity and are refused. Current releases also check
online archive provenance when authentication is available.
The bundled installer
preserves configuration, credentials, packs, and local evidence. A failure
before the selected binary can run restores the prior
installation. A later failure keeps both binaries and leaves the service stopped
for explicit recovery. Every selected release must expose the offline
dispatch-state check and the current managed-installer transaction. The check
binds the configured data directory to the installer receipt before the bundled
installer runs.

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
			})
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "install an exact immutable runner version")
	return cmd
}
