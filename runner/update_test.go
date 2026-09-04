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
	for _, want := range []string{"checksum file is authenticated", "Sigstore bundle", "installer receipt", "rolls back"} {
		if !strings.Contains(command.Long, want) {
			t.Errorf("long help missing %q:\n%s", want, command.Long)
		}
	}
	flag := command.Flags().Lookup("version")
	if flag == nil || flag.DefValue != "" {
		t.Fatalf("--version flag = %#v", flag)
	}
}
