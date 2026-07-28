package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// encodeFixtureAction marshals the whole action document, so a multi-line shell
// program round-trips as the shell it is testing instead of being spliced into
// hand-built YAML.
func encodeFixtureAction(t *testing.T, id string, command map[string]any) []byte {
	t.Helper()
	encoded, err := yaml.Marshal(map[string]any{
		"schema_version": 1,
		"id":             id,
		"execution":      map[string]any{"command": command},
	})
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestValidatePackPipelineFailures(t *testing.T) {
	tests := []struct {
		name       string
		id         string
		program    string
		wantErr    bool
		wantErrMsg string
	}{
		{
			name:    "guarded log read",
			id:      "fixture.guarded",
			program: "[ -r \"$1\" ] || { echo missing >&2; exit 1; }\ngrep -E ' 5[0-9][0-9] ' \"$1\" | tail -n 100",
		},
		{
			name:       "unguarded positional log read",
			id:         "fixture.unguarded_positional",
			program:    "grep -E ' 5[0-9][0-9] ' \"$1\" | tail -n 100",
			wantErr:    true,
			wantErrMsg: "fixture.unguarded_positional",
		},
		{
			// The alternation is regex syntax; reading it as the pipe truncates
			// the segment before "$1" and the real masking goes unseen.
			name:       "pipe inside a quoted regex is not the pipeline",
			id:         "fixture.regex_alternation",
			program:    "grep -E '(\"DownstreamStatus\":5[0-9][0-9]| 5[0-9][0-9] )' \"$1\" | tail -n 100",
			wantErr:    true,
			wantErrMsg: "fixture.regex_alternation",
		},
		{
			name:       "unguarded literal log read",
			id:         "fixture.unguarded_literal",
			program:    "tail -n 1000 /var/log/nginx/access.log | awk '{print $1}' | sort | uniq -c | head -20",
			wantErr:    true,
			wantErrMsg: "fixture.unguarded_literal",
		},
		{
			name:    "directory guard covers a traversal",
			id:      "fixture.guarded_dir",
			program: "[ -d \"$1\" ] || { echo missing >&2; exit 1; }\nfind \"$1\" -type f 2>/dev/null | head -500",
		},
		{
			name:    "captured status is propagated",
			id:      "fixture.status_propagated",
			program: "dump=$(nginx -T 2>&1); status=$?\nprintf '%s\\n' \"$dump\" | head -800\nexit $status",
		},
		{
			name:    "local enumerator needs no guard",
			id:      "fixture.enumerator",
			program: "ps -eo pid,user,pcpu --sort=-pcpu | head -n 20",
		},
		{
			// `||` is a fallback operator, not a pipe: the left side's failure
			// is what selects the right side, so nothing is masked.
			name:    "or fallback is not a pipeline",
			id:      "fixture.or_fallback",
			program: "cat /var/named/data/named_stats.txt 2>/dev/null || cat /var/cache/bind/named.stats",
		},
		{
			name:       "trailing assignment does not hide the reader",
			id:         "fixture.assignment_prefix",
			program:    "V=${PY_VENV:-/opt/app/venv}; SP=$(\"$V/bin/python\" -c 'import site'); du -sh \"$SP\"/* 2>/dev/null | sort -rh | head -50",
			wantErr:    true,
			wantErrMsg: "fixture.assignment_prefix",
		},
		{
			name:    "comments are not scanned",
			id:      "fixture.commented",
			program: "# grep foo /var/log/x | tail -n 5\n[ -r \"$1\" ] || exit 1\ngrep foo \"$1\" | tail -n 5",
		},
		{
			name:    "non-shell action is out of scope",
			id:      "fixture.not_shell",
			program: "",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			actionDir := filepath.Join(packDir, "actions")
			if err := os.MkdirAll(actionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			command := map[string]any{
				"binary": "curl",
				"argv":   []string{"-fsS", "http://service"},
			}
			if test.program != "" {
				command = map[string]any{
					"binary": "/bin/sh",
					"argv":   []string{"-c", test.program},
				}
			}
			action := encodeFixtureAction(t, test.id, command)
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), action, 0o644); err != nil {
				t.Fatal(err)
			}

			err := validatePackPipelineFailures(packDir)
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

func TestPipelineLintCoversTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackPipelineFailures(packDir); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
