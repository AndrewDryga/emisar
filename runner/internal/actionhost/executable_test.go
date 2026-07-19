package actionhost

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestPrimaryExecutable(t *testing.T) {
	tests := []struct {
		name   string
		action *actionspec.Action
		want   string
	}{
		{
			name: "exec",
			action: &actionspec.Action{Kind: actionspec.KindExec, Execution: actionspec.Execution{
				Command: &actionspec.Command{Binary: "redis-cli"},
			}},
			want: "redis-cli",
		},
		{
			name: "script interpreter",
			action: &actionspec.Action{Kind: actionspec.KindScript, Execution: actionspec.Execution{
				Script: &actionspec.Script{Interpreter: "/usr/bin/env"},
			}},
			want: "/usr/bin/env",
		},
		{
			name: "script default",
			action: &actionspec.Action{Kind: actionspec.KindScript, Execution: actionspec.Execution{
				Script: &actionspec.Script{},
			}},
			want: "/bin/sh",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := PrimaryExecutable(tt.action); got != tt.want {
				t.Fatalf("PrimaryExecutable() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestPrimaryExecutableAvailable(t *testing.T) {
	dir := t.TempDir()
	executable := filepath.Join(dir, "available")
	nonExecutable := filepath.Join(dir, "not-executable")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(nonExecutable, []byte("data\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	for _, tt := range []struct {
		binary string
		want   bool
	}{
		{"available", true},
		{executable, true},
		{nonExecutable, false},
		{"missing", false},
	} {
		action := &actionspec.Action{Kind: actionspec.KindExec, Execution: actionspec.Execution{
			Command: &actionspec.Command{Binary: tt.binary},
		}}
		if got := PrimaryExecutableAvailable(action); got != tt.want {
			t.Errorf("PrimaryExecutableAvailable(%q) = %t, want %t", tt.binary, got, tt.want)
		}
	}
}
