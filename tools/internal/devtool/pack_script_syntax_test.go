package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackScriptSyntax(t *testing.T) {
	tests := []struct {
		name        string
		id          string
		interpreter string
		script      string
		wantErr     bool
		wantErrMsg  string
	}{
		{
			// The class that shipped: a quote opened inside a printf format and
			// never closed, which every later line then reads as one string.
			name:        "unmatched single quote does not parse",
			id:          "fixture.unmatched_quote",
			interpreter: "/bin/sh",
			script:      "#!/bin/sh\nset -eu\nprintf '%s\\n' 'unterminated\necho done\n",
			wantErr:     true,
			wantErrMsg:  "/bin/sh scripts/action.sh (fixture.unmatched_quote)",
		},
		{
			name:        "a valid sh script parses",
			id:          "fixture.valid_sh",
			interpreter: "/bin/sh",
			script:      "#!/bin/sh\nset -eu\n[ -r \"$1\" ] || exit 1\ngrep -c ERROR \"$1\" || true\n",
		},
		{
			// executor.PlanForScript runs a blank interpreter under /bin/sh, so
			// the lint parses it rather than skipping it.
			name:       "a blank interpreter defaults to /bin/sh",
			id:         "fixture.blank_interpreter",
			script:     "#!/bin/sh\nif [ -r \"$1\" ]; then\n  cat \"$1\"\n",
			wantErr:    true,
			wantErrMsg: "/bin/sh scripts/action.sh (fixture.blank_interpreter)",
		},
		{
			name:   "a valid script under the default interpreter parses",
			id:     "fixture.blank_valid",
			script: "#!/bin/sh\nwhile read -r line; do\n  printf '%s\\n' \"$line\"\ndone\n",
		},
		{
			name:        "a valid bash script parses",
			id:          "fixture.valid_bash",
			interpreter: "/bin/bash",
			script:      "#!/bin/bash\nset -euo pipefail\ndeclare -a units=()\nif [[ \"$1\" == *.service ]]; then\n  units+=(\"$1\")\nfi\nprintf '%s\\n' \"${units[@]}\"\n",
		},
		{
			name:        "an unclosed bash function does not parse",
			id:          "fixture.unclosed_bash",
			interpreter: "/bin/bash",
			script:      "#!/bin/bash\nset -euo pipefail\nemit() {\n  printf '%s\\n' \"$1\"\n",
			wantErr:     true,
			wantErrMsg:  "/bin/bash scripts/action.sh (fixture.unclosed_bash)",
		},
		{
			// Only shell syntax is in scope; another interpreter's `-n` means
			// something else entirely, or nothing.
			name:        "a non-shell interpreter is out of scope",
			id:          "fixture.python",
			interpreter: "/usr/bin/python3",
			script:      "import sys\nprint(sys.argv[1])\n",
		},
		{
			name: "an exec action has no script to parse",
			id:   "fixture.exec_only",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			actionDir := filepath.Join(packDir, "actions")
			if err := os.MkdirAll(actionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			execution := map[string]any{
				"command": map[string]any{
					"binary": "systemctl",
					"argv":   []string{"list-units"},
				},
			}
			if test.script != "" {
				script := map[string]any{"path": "scripts/action.sh"}
				if test.interpreter != "" {
					script["interpreter"] = test.interpreter
				}
				execution = map[string]any{"script": script}
				writeFixtureScript(t, packDir, "action.sh", test.script)
			}
			action := encodeFixtureAction(t, test.id, execution)
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), action, 0o644); err != nil {
				t.Fatal(err)
			}

			err := validatePackScriptSyntax(t.Context(), fixturePackActionLintInput(t, packDir))
			if test.wantErr {
				if err == nil || !strings.Contains(err.Error(), test.wantErrMsg) {
					t.Fatalf("error = %v, want containing %q", err, test.wantErrMsg)
				}
			} else if err != nil {
				t.Fatal(err)
			}
		})
	}
}

// A script parsed once for several actions still has to say which actions it
// breaks — 320 catalog actions share 49 files.
func TestPackScriptSyntaxNamesASharedScript(t *testing.T) {
	packDir := t.TempDir()
	actionDir := filepath.Join(packDir, "actions")
	if err := os.MkdirAll(actionDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixtureScript(t, packDir, "shared.sh", "#!/bin/sh\ncase \"$1\" in\n  a) echo a ;;\n")
	execution := map[string]any{
		"script": map[string]any{"path": "scripts/shared.sh", "interpreter": "/bin/sh"},
	}
	for _, id := range []string{"fixture.shared_two", "fixture.shared_one"} {
		if err := os.WriteFile(
			filepath.Join(actionDir, id+".yaml"), encodeFixtureAction(t, id, execution), 0o644,
		); err != nil {
			t.Fatal(err)
		}
	}

	err := validatePackScriptSyntax(t.Context(), fixturePackActionLintInput(t, packDir))
	if err == nil || !strings.Contains(err.Error(), "fixture.shared_one and 1 more") {
		t.Fatalf("error = %v, want containing %q", err, "fixture.shared_one and 1 more")
	}
	// The shell's own diagnostic is what says where to look; every shell words
	// it differently, so only the part they share is asserted.
	if !strings.Contains(strings.ToLower(err.Error()), "syntax error") {
		t.Fatalf("error = %v, want the shell diagnostic", err)
	}
}

func TestScriptSyntaxLintCoversTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackScriptSyntax(t.Context(), mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}

func writeFixtureScript(t *testing.T, packDir, name, body string) {
	t.Helper()
	scriptDir := filepath.Join(packDir, "scripts")
	if err := os.MkdirAll(scriptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scriptDir, name), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
