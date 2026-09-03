package main

import (
	"strings"
	"testing"
)

func TestUpdateCommandDocumentsVerifiedInstallerManagedBoundary(t *testing.T) {
	command := updateCmd()
	if command.Use != "update" || command.Args == nil {
		t.Fatalf("unexpected command shape: use=%q args=%v", command.Use, command.Args)
	}
	for _, want := range []string{
		"checksum is authenticated",
		"downloaded Sigstore bundle",
		"GitHub login is not required",
		"public Sigstore trust-root services",
		"online archive provenance",
		"only accepted pre-bundle rollback target",
		"earlier tags have no accepted",
		"installer receipt",
		"Container",
		"keeps both binaries",
		"managed-installer transaction",
		"binds the configured data directory",
	} {
		if !strings.Contains(command.Long, want) {
			t.Errorf("long help missing %q:\n%s", want, command.Long)
		}
	}
	flag := command.Flags().Lookup("version")
	if flag == nil || flag.DefValue != "" {
		t.Fatalf("--version flag = %#v", flag)
	}
}
