package expressions

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"go.yaml.in/yaml/v3"
)

func tailscalePingAction(t *testing.T) actionspec.Action {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "packs", "tailscale", "actions", "ping.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var action actionspec.Action
	if err := yaml.Unmarshal(raw, &action); err != nil {
		t.Fatal(err)
	}
	if err := action.Validate(); err != nil {
		t.Fatal(err)
	}
	return action
}

// This proves the real descriptor's validated/rendered operands reach a
// process unchanged. Vendor ping semantics are separately qualified with the
// actual CLI against isolated LocalAPI responses, not implemented by this stub.
func TestTailscalePingArgv(t *testing.T) {
	action := tailscalePingAction(t)
	if action.Execution.Command == nil || action.Execution.Command.Binary != "tailscale" || len(action.Execution.SuccessExitCodes) != 0 {
		t.Fatalf("ping must use the native CLI without forgiving failures: %#v", action.Execution)
	}
	for _, tt := range []struct {
		name string
		raw  map[string]any
		want int
	}{
		{"default", map[string]any{"host": "fixture-peer.example"}, 5},
		{"minimum", map[string]any{"host": "100.100.100.100", "count": 1}, 1},
		{"maximum_ipv6", map[string]any{"host": "fd7a:115c:a1e0::1", "count": 20}, 20},
	} {
		t.Run(tt.name, func(t *testing.T) {
			args, err := validation.Validate(action.Args, tt.raw, nil)
			if err != nil {
				t.Fatal(err)
			}
			argv, err := RenderArgv(action.Execution.Command.Argv, args)
			if err != nil {
				t.Fatal(err)
			}
			want := []string{"ping", "--until-direct=false", "--timeout=5s", "--c", strconv.Itoa(tt.want), tt.raw["host"].(string)}
			if !reflect.DeepEqual(argv, want) {
				t.Fatalf("native exact-count/reachability flags: got %#v want %#v", argv, want)
			}
			dir := t.TempDir()
			stub := filepath.Join(dir, "tailscale")
			if err := os.WriteFile(stub, []byte("#!/bin/sh\nset -eu\nprintf '%s\\000' \"$@\"\nprintf '%s\\n' 'fixture native error' >&2\nexit 7\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, stub, argv...)
			var out, diagnostic bytes.Buffer
			cmd.Stdout, cmd.Stderr = &out, &diagnostic
			var exit *exec.ExitError
			if err := cmd.Run(); !errors.As(err, &exit) || exit.ExitCode() != 7 {
				t.Fatalf("native nonzero status lost: %v", err)
			}
			if out.String() != strings.Join(want, "\x00")+"\x00" || diagnostic.String() != "fixture native error\n" {
				t.Fatalf("process operands/diagnostic changed: %q, %q", out.String(), diagnostic.String())
			}
		})
	}
	// Each of the twenty probes can wait five seconds, then sleep a second
	// after a reply. Keep extra budget for LocalAPI setup rather than letting
	// the old thirty-second action deadline silently cut the requested count.
	if time.Duration(action.Execution.Timeout) < 20*(5*time.Second+time.Second)+30*time.Second {
		t.Fatalf("maximum count cannot fit the action deadline: %s", time.Duration(action.Execution.Timeout))
	}
}

func TestTailscalePingRejectsInvalidArguments(t *testing.T) {
	action := tailscalePingAction(t)
	for _, tt := range []struct {
		name string
		args map[string]any
	}{
		{"missing_host", map[string]any{}},
		{"empty_host", map[string]any{"host": ""}},
		{"flag_host", map[string]any{"host": "--icmp"}},
		{"shell_host", map[string]any{"host": "peer;touch injected"}},
		{"oversized_host", map[string]any{"host": strings.Repeat("a", 129)}},
		{"count_zero", map[string]any{"host": "peer", "count": 0}},
		{"count_overflow", map[string]any{"host": "peer", "count": 21}},
		{"count_fractional", map[string]any{"host": "peer", "count": 1.5}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := validation.Validate(action.Args, tt.args, nil); err == nil {
				t.Fatalf("invalid ping operands accepted: %#v", tt.args)
			}
		})
	}
}
