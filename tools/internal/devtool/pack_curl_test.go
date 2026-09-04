package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackCurlURLSafety(t *testing.T) {
	tests := []struct {
		name       string
		id         string
		execution  string
		script     string
		wantErr    bool
		wantErrMsg string
	}{
		{
			name:      "inline shell pins globbing and protocol",
			id:        "fixture.safe_shell",
			execution: "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -fsS --globoff --proto =http,https \"${BASE:-http://svc}/x\"']",
		},
		{
			name:       "inline shell leaves globbing on",
			id:         "fixture.globbing_shell",
			execution:  "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -fsS --proto =http,https \"${BASE:-http://svc}/x\"']",
			wantErr:    true,
			wantErrMsg: "fixture.globbing_shell (no --globoff)",
		},
		{
			name:       "inline shell leaves the protocol open",
			id:         "fixture.open_proto",
			execution:  "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -fsS --globoff \"${BASE:-http://svc}/x\"']",
			wantErr:    true,
			wantErrMsg: "fixture.open_proto (no --proto)",
		},
		{
			name:      "-g is curl's short --globoff",
			id:        "fixture.short_globoff",
			execution: "command:\n    binary: curl\n    argv: [-g, --proto, '=https', 'https://svc/x']",
		},
		{
			name:       "redirect-following call must pin the redirect too",
			id:         "fixture.follows",
			execution:  "command:\n    binary: curl\n    argv: [-sIL, --globoff, --proto, '=https', 'https://svc/x']",
			wantErr:    true,
			wantErrMsg: "fixture.follows (follows redirects without --proto-redir)",
		},
		{
			name:       "redirect-following call must bound the hop count too",
			id:         "fixture.follows_unbounded",
			execution:  "command:\n    binary: curl\n    argv: [-sIL, --globoff, --proto, '=https', --proto-redir, '=https', 'https://svc/x']",
			wantErr:    true,
			wantErrMsg: "fixture.follows_unbounded (follows redirects without --max-redirs)",
		},
		{
			name:      "redirect-following call with --proto-redir and --max-redirs passes",
			id:        "fixture.follows_pinned",
			execution: "command:\n    binary: curl\n    argv: [-sIL, --globoff, --proto, '=https', --proto-redir, '=https', --max-redirs, '1', 'https://svc/x']",
		},
		{
			name:      "flags wrapped across a line continuation still count",
			id:        "fixture.wrapped_script",
			execution: "script:\n    path: scripts/request.sh",
			script:    "#!/bin/sh\ncurl --fail --silent --globoff \\\n  --proto '=https' \"$1\"\n",
		},
		{
			name:       "wrapped script still missing a flag is caught",
			id:         "fixture.wrapped_gap",
			execution:  "script:\n    path: scripts/request.sh",
			script:     "#!/bin/sh\ncurl --fail --silent \\\n  --proto '=https' \"$1\"\n",
			wantErr:    true,
			wantErrMsg: "fixture.wrapped_gap (no --globoff)",
		},
		{
			name:      "flags assembled indirectly are judged from the script",
			id:        "fixture.indirect",
			execution: "script:\n    path: scripts/request.sh",
			script:    "#!/bin/sh\nset -- --globoff --proto '=https' -sS\ncurl \"$@\" \"$1\"\n",
		},
		{
			name:       "indirect assembly with no flags anywhere is caught",
			id:         "fixture.indirect_gap",
			execution:  "script:\n    path: scripts/request.sh",
			script:     "#!/bin/sh\nset -- -sS\ncurl \"$@\" \"$1\"\n",
			wantErr:    true,
			wantErrMsg: "fixture.indirect_gap (no --globoff)",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			actionDir := filepath.Join(packDir, "actions")
			if err := os.MkdirAll(actionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			action := "schema_version: 1\nid: " + test.id + "\nexecution:\n  " + test.execution + "\n"
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), []byte(action), 0o644); err != nil {
				t.Fatal(err)
			}
			if test.script != "" {
				scriptDir := filepath.Join(packDir, "scripts")
				if err := os.MkdirAll(scriptDir, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(scriptDir, "request.sh"), []byte(test.script), 0o755); err != nil {
					t.Fatal(err)
				}
			}

			err := validatePackCurlURLSafety(fixturePackActionLintInput(t, packDir))
			if test.wantErr {
				if err == nil || !strings.Contains(err.Error(), test.wantErrMsg) {
					t.Fatalf("error = %v, want containing %q", err, test.wantErrMsg)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}
