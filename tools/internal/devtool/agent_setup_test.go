package devtool

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgentSetupCheckRequiresHostCLIOnlyOnHost(t *testing.T) {
	for _, box := range []string{"", "1", "true"} {
		t.Run("COOP_BOX="+box, func(t *testing.T) {
			app := testApp(t)
			t.Setenv("COOP_BOX", box)
			bin := t.TempDir()
			log := filepath.Join(t.TempDir(), "go-args")
			t.Setenv("AGENT_SETUP_TEST_LOG", log)
			if err := os.WriteFile(filepath.Join(bin, "go"), []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$AGENT_SETUP_TEST_LOG\"\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin)
			if err := app.Run(context.Background(), []string{"check", "agent-setup"}); err != nil {
				t.Fatal(err)
			}
			args, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			want := "run\n./tools/cmd/agentcheck\n"
			if box != "1" {
				want += "--require-coop\n"
			}
			if string(args) != want {
				t.Fatalf("agent setup command = %q, want %q", args, want)
			}
		})
	}
}

func TestAgentSetupCheckPreservesFailureInBox(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "go"), []byte("#!/bin/sh\nexit 23\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	if err := app.Run(context.Background(), []string{"check", "agent-setup"}); err == nil || !strings.Contains(err.Error(), "exit status 23") {
		t.Fatalf("failed repository setup check was lost: %v", err)
	}
}
