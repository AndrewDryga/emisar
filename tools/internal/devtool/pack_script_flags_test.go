package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackScriptFlags(t *testing.T) {
	for _, test := range []struct {
		name        string
		id          string
		interpreter string
		script      string
		wantErr     string
	}{
		{
			// The shape that shipped: a multi-step script with no floor, so a
			// failed login left an empty session token and the read ran anyway.
			name:    "no flags at all",
			id:      "fixture.no_flags",
			script:  "#!/bin/sh\n# a comment\nAPI=${API:-http://127.0.0.1}\ncurl -fsS \"$API\"\n",
			wantErr: `scripts/action.sh (fixture.no_flags): expected "set -eu"`,
		},
		{
			name:    "only -u",
			id:      "fixture.only_u",
			script:  "#!/bin/sh\nset -u\ncurl -fsS \"$API\"\n",
			wantErr: `expected "set -eu"`,
		},
		{
			// After the first command is too late: that command ran unguarded.
			name:    "flags after the first command",
			id:      "fixture.late_flags",
			script:  "#!/bin/sh\nAPI=${API:-http://127.0.0.1}\nset -eu\ncurl -fsS \"$API\"\n",
			wantErr: `expected "set -eu"`,
		},
		{
			name:   "sh floor",
			id:     "fixture.sh_floor",
			script: "#!/bin/sh\n\n# why this exists\nset -eu\n\ncurl -fsS \"$API\"\n",
		},
		{
			// pipefail is a bash builtin; a /bin/sh script that carried it would
			// fail to start under busybox ash.
			name:        "bash floor",
			id:          "fixture.bash_floor",
			interpreter: "/bin/bash",
			script:      "#!/bin/bash\nset -euo pipefail\ncurl -fsS \"$API\"\n",
		},
		{
			name:        "bash without pipefail",
			id:          "fixture.bash_no_pipefail",
			interpreter: "/bin/bash",
			script:      "#!/bin/bash\nset -eu\ncurl -fsS \"$API\"\n",
			wantErr:     `expected "set -euo pipefail"`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			writeFixtureScript(t, packDir, "action.sh", test.script)
			script := map[string]any{"path": "scripts/action.sh"}
			if test.interpreter != "" {
				script["interpreter"] = test.interpreter
			}
			actionDir := filepath.Join(packDir, "actions")
			if err := os.MkdirAll(actionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			action := encodeFixtureAction(t, test.id, map[string]any{"script": script})
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), action, 0o644); err != nil {
				t.Fatal(err)
			}

			err := validatePackScriptFlags(fixturePackActionLintInput(t, packDir))
			if test.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("error = %v, want %q", err, test.wantErr)
			}
		})
	}
}

func TestScriptFlagLintCoversTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackScriptFlags(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
