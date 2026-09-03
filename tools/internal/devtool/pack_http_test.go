package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackHTTPFailures(t *testing.T) {
	tests := []struct {
		name       string
		id         string
		execution  string
		script     string
		wantErr    bool
		wantErrMsg string
	}{
		{
			name:      "inline shell fails HTTP errors",
			id:        "fixture.safe_shell",
			execution: "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -fsS http://service/resource']",
		},
		{
			name:       "inline shell accepts HTTP errors",
			id:         "fixture.unsafe_shell",
			execution:  "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -sS http://service/resource']",
			wantErr:    true,
			wantErrMsg: "fixture.unsafe_shell",
		},
		{
			name:      "direct curl fails HTTP errors",
			id:        "fixture.safe_argv",
			execution: "command:\n    binary: curl\n    argv: [-sSfX, GET, http://service/resource]",
		},
		{
			name:       "direct curl accepts HTTP errors",
			id:         "fixture.unsafe_argv",
			execution:  "command:\n    binary: curl\n    argv: [-sS, http://service/resource]",
			wantErr:    true,
			wantErrMsg: "fixture.unsafe_argv",
		},
		{
			name:      "packaged script fails HTTP errors",
			id:        "fixture.safe_script",
			execution: "script:\n    path: scripts/request.sh",
			script:    "#!/bin/sh\ncurl --fail --silent --show-error http://service/resource\n",
		},
		{
			name:       "packaged script accepts HTTP errors",
			id:         "fixture.unsafe_script",
			execution:  "script:\n    path: scripts/request.sh",
			script:     "#!/bin/sh\ncurl -sS http://service/resource\n",
			wantErr:    true,
			wantErrMsg: "fixture.unsafe_script",
		},
		{
			name:      "packaged script explicitly checks 2xx",
			id:        "fixture.manual_status",
			execution: "script:\n    path: scripts/request.sh",
			script:    "#!/bin/sh\ncode=$(curl -sS -o body -w '%{http_code}' http://service/resource)\ncase \"$code\" in\n\t2*) ;;\n\t*) echo \"curl failed\" >&2; exit 1 ;;\nesac\n",
		},
		{
			name:       "manual check does not mask another unsafe request",
			id:         "fixture.mixed_script",
			execution:  "script:\n    path: scripts/request.sh",
			script:     "#!/bin/sh\ncode=$(curl -sS -o body -w '%{http_code}' http://service/resource)\ncase \"$code\" in\n\t2*) ;;\n\t*) exit 1 ;;\nesac\ncurl -sS http://service/other\n",
			wantErr:    true,
			wantErrMsg: "fixture.mixed_script",
		},
		{
			name:      "status-reporting diagnostic is explicit exception",
			id:        "net.http_probe",
			execution: "command:\n    binary: /bin/sh\n    argv: [-c, 'curl -sS -w %{http_code} http://service/resource']",
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

			err := validatePackHTTPFailures(fixturePackActionLintInput(t, packDir))
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
