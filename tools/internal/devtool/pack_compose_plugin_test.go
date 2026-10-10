//go:build !windows

package devtool

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

type composePluginCommand struct {
	id, binary string
	argv, want []string
}

// Load the six actual manifest paths, not a copied guard. The file value also
// deliberately contains shell syntax; validation normally rejects it, but the
// command construction must still keep every rendered argument opaque.
func composePluginCommands(t *testing.T) []composePluginCommand {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", "packs", "docker"))
	if err != nil {
		t.Fatal(err)
	}
	file := "/opt/stack/$(printf should-not-execute);literal.yml"
	want := map[string][]string{
		"docker.compose_ls":      {"compose", "ls", "--all", "--format", "json"},
		"docker.compose_ps":      {"compose", "-f", file, "ps", "-a"},
		"docker.compose_logs":    {"compose", "-f", file, "logs", "--tail", "37", "app"},
		"docker.compose_restart": {"compose", "-f", file, "restart", "app"},
		"docker.compose_config":  {"compose", "-f", file, "--profile", "*", "config", "--no-interpolate", "--no-env-resolution", "--quiet"},
		"docker.compose_images":  {"compose", "-f", file, "images", "--format", "json"},
	}
	input := mustLoadPackActionLintInput(t, root)
	var commands []composePluginCommand
	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var action struct {
			ID        string `yaml:"id"`
			Kind      string `yaml:"kind"`
			Execution struct {
				Command struct {
					Binary string   `yaml:"binary"`
					Argv   []string `yaml:"argv"`
				} `yaml:"command"`
				Script struct {
					Path        string `yaml:"path"`
					Interpreter string `yaml:"interpreter"`
				} `yaml:"script"`
				Argv []string `yaml:"argv"`
			} `yaml:"execution"`
		}
		if err := yaml.Unmarshal(data, &action); err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(action.ID, "docker.compose_") {
			continue
		}
		expected, ok := want[action.ID]
		if !ok {
			t.Fatalf("new Compose execution path needs guard coverage: %s", action.ID)
		}
		command := composePluginCommand{id: action.ID, want: expected}
		switch action.Kind {
		case "exec":
			command.binary, command.argv = action.Execution.Command.Binary, action.Execution.Command.Argv
		case "script":
			command.binary = action.Execution.Script.Interpreter
			command.argv = append([]string{filepath.Join(root, action.Execution.Script.Path)}, action.Execution.Argv...)
		default:
			t.Fatalf("unexpected Compose execution kind: %s", action.Kind)
		}
		render := strings.NewReplacer("{{ args.file }}", file, "{{ args.service }}", "app", "{{ args.lines }}", "37")
		for i, arg := range command.argv {
			command.argv[i] = render.Replace(arg)
			if strings.Contains(command.argv[i], "{{") {
				t.Fatalf("unhandled Compose argument: %q", arg)
			}
		}
		commands = append(commands, command)
	}
	if len(commands) != len(want) {
		t.Fatalf("loaded %d Compose actions, expected all %d", len(commands), len(want))
	}
	return commands
}

const composePluginStub = `#!/bin/sh
set -eu
{
  printf 'call\000'
  printf '%s\000' "$@"
  printf '\000'
} >> "$STUB_CALLS"
if [ "$#" -eq 2 ] && [ "$1" = compose ] && [ "$2" = version ]; then
  if [ "$STUB_PROBE_RC" -ne 0 ]; then printf '%s\n' "$STUB_PROBE_TEXT" >&2; fi
  exit "$STUB_PROBE_RC"
fi
if [ "$STUB_DOWNSTREAM_RC" -ne 0 ]; then
  printf '%s\n' 'stub downstream failed' >&2
  exit "$STUB_DOWNSTREAM_RC"
fi
case " $* " in
  *" --quiet "*) ;;
  *" --services "*) printf 'app\n' ;;
  *" --networks "*) printf 'default\n' ;;
  *" --volumes "*) printf 'data\n' ;;
  *" config "*) printf '%s\n' '{"services":{"app":{"image":"fixture:latest","profiles":["fixture"]}}}' ;;
  *" images "*|*" ls "*) printf '[]\n' ;;
  *) printf 'fixture downstream\n' ;;
esac
`

func TestDockerComposePluginPreflightOnEveryExecutionPath(t *testing.T) {
	for _, command := range composePluginCommands(t) {
		for _, tc := range []struct {
			name, diagnostic          string
			probe, downstream, result int
			absent                    bool
		}{
			{name: "Docker 27 absence", probe: 1, diagnostic: "docker: 'compose' is not a docker command.\nSee 'docker --help'", result: 127, absent: true},
			{name: "Docker 29 absence", probe: 1, diagnostic: "docker: unknown command: docker compose\n\nRun 'docker --help' for more information", result: 127, absent: true},
			{name: "context failure", probe: 1, diagnostic: "unable to resolve docker endpoint: context fixture not found", result: 1},
			{name: "plugin execution failure", probe: 42, diagnostic: "fixture plugin execution failed", result: 42},
			{name: "same text wrong status", probe: 2, diagnostic: "docker: unknown command: docker compose\n\nRun 'docker --help' for more information", result: 2},
			{name: "unrelated diagnostic mentions absence", probe: 1, diagnostic: "invalid config: docker: unknown command: docker compose", result: 1},
			{name: "plugin present, unchanged argv"},
			{name: "downstream failure", downstream: 7, result: 7},
		} {
			t.Run(command.id+"/"+tc.name, func(t *testing.T) {
				bin := t.TempDir()
				if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(composePluginStub), 0o755); err != nil {
					t.Fatal(err)
				}
				callsPath := filepath.Join(t.TempDir(), "calls")
				cmd := exec.Command(command.binary, command.argv...)
				cmd.Env = []string{
					"PATH=" + bin + string(os.PathListSeparator) + os.Getenv("PATH"), "LC_ALL=" + composeConfigLocale(),
					"STUB_CALLS=" + callsPath, "STUB_PROBE_TEXT=" + tc.diagnostic,
					"STUB_PROBE_RC=" + strconv.Itoa(tc.probe), "STUB_DOWNSTREAM_RC=" + strconv.Itoa(tc.downstream),
				}
				configureProcessGroup(cmd)
				var out, stderr bytes.Buffer
				cmd.Stdout, cmd.Stderr = &out, &stderr
				err := waitResponseCommand(t, cmd)
				exit := 0
				if err != nil {
					var status *exec.ExitError
					if !errors.As(err, &status) {
						t.Fatal(err)
					}
					exit = status.ExitCode()
				}
				if exit != tc.result {
					t.Fatalf("exit=%d want=%d stderr=%s", exit, tc.result, &stderr)
				}
				data, err := os.ReadFile(callsPath)
				if err != nil {
					t.Fatal(err)
				}
				var calls [][]string
				for _, record := range strings.Split(strings.TrimSuffix(string(data), "\x00\x00"), "\x00\x00") {
					parts := strings.Split(record, "\x00")
					if parts[0] != "call" {
						t.Fatalf("malformed fixture call: %q", record)
					}
					calls = append(calls, parts[1:])
				}
				if !reflect.DeepEqual(calls[0], []string{"compose", "version"}) {
					t.Fatalf("first command was not the isolated plugin probe: %v", calls)
				}
				if tc.probe != 0 {
					wantDiagnostic := tc.diagnostic + "\n"
					if tc.absent {
						wantDiagnostic = "docker compose plugin is not installed\n"
					}
					if len(calls) != 1 || out.Len() != 0 || stderr.String() != wantDiagnostic {
						t.Fatalf("probe failure was obscured or command ran: calls=%v stdout=%s stderr=%s", calls, &out, &stderr)
					}
				} else {
					if len(calls) < 2 || !reflect.DeepEqual(calls[1], command.want) {
						t.Fatalf("downstream argv changed or shell syntax executed: got=%v want=%v", calls, command.want)
					}
					if tc.downstream != 0 && (len(calls) != 2 || out.Len() != 0 || stderr.String() != "stub downstream failed\n") {
						t.Fatalf("downstream failure changed: calls=%v stdout=%s stderr=%s", calls, &out, &stderr)
					}
				}
			})
		}
	}
}
