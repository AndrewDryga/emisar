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
func encodeFixtureAction(t *testing.T, id string, execution map[string]any) []byte {
	t.Helper()
	encoded, err := yaml.Marshal(map[string]any{
		"schema_version": 1,
		"id":             id,
		"execution":      execution,
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
		script     string
		wantErr    bool
		wantErrMsg string
	}{
		{
			name:       "packaged script masks its source too",
			id:         "fixture.unguarded_script",
			script:     "#!/bin/sh\ngrep -F 'SLOW' \"$1\" | tail -n 100\n",
			wantErr:    true,
			wantErrMsg: "fixture.unguarded_script",
		},
		{
			name:   "packaged script guarded by pipefail",
			id:     "fixture.script_pipefail",
			script: "#!/usr/bin/env bash\nset -euo pipefail\ndu -sh /var/lib/x/* 2>/dev/null | sort -h | tail -20\n",
		},
		{
			name:    "guarded log read",
			id:      "fixture.guarded",
			program: "[ -r \"$1\" ] || { echo missing >&2; exit 1; }\ngrep -E ' 5[0-9][0-9] ' \"$1\" | tail -n 100",
		},
		{
			// postfix.queue_counts shipped this shape: the `do` stopped the
			// scanner before it read any command, and `n=$(find` looked like an
			// environment assignment to strip rather than an assignment whose
			// value IS the source.
			name:       "a loop body's command substitution is still a pipeline",
			id:         "fixture.loop_substitution",
			program:    "for q in a b; do n=$(find /var/spool/x/$q -type f 2>/dev/null | wc -l); echo \"$q: $n\"; done",
			wantErr:    true,
			wantErrMsg: "fixture.loop_substitution",
		},
		{
			name:       "a loop body's bare pipeline is still a pipeline",
			id:         "fixture.loop_bare",
			program:    "for q in a b; do grep -F ERROR /var/log/$q.log | tail -n 20; done",
			wantErr:    true,
			wantErrMsg: "fixture.loop_bare",
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
			name:       "grouped kernel source fallback is still fallible",
			id:         "fixture.grouped_kernel_fallback",
			program:    "{ dmesg -T 2>/dev/null || journalctl -k --no-pager; } | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.grouped_kernel_fallback",
		},
		{
			name:       "exit fallback inside a grouped source does not guard the pipe",
			id:         "fixture.grouped_kernel_exit",
			program:    "{ dmesg -T 2>/dev/null || journalctl -k --no-pager || exit 1; } | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.grouped_kernel_exit",
		},
		{
			name:       "error block inside a grouped source does not guard the pipe",
			id:         "fixture.grouped_kernel_error_block",
			program:    "{ dmesg -T 2>/dev/null || journalctl -k --no-pager || { echo unreadable >&2; exit 1; }; } | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.grouped_kernel_error_block",
		},
		{
			name:       "comment mentioning pipefail does not guard a grouped source",
			id:         "fixture.grouped_kernel_pipefail_comment",
			program:    "# pipefail is unavailable\n{ dmesg -T 2>/dev/null || journalctl -k --no-pager; } | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.grouped_kernel_pipefail_comment",
		},
		{
			name:       "journal source failure is not masked",
			id:         "fixture.journalctl",
			program:    "journalctl -b -p err --no-pager | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.journalctl",
		},
		{
			name:       "unrelated path guard does not protect a journal source",
			id:         "fixture.guarded_journalctl",
			program:    "[ -r /run/log/journal ] || { exit 1; }\njournalctl -b -p err --no-pager | tail -100",
			wantErr:    true,
			wantErrMsg: "fixture.guarded_journalctl",
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
			execution := map[string]any{
				"command": map[string]any{
					"binary": "curl",
					"argv":   []string{"-fsS", "http://service"},
				},
			}
			switch {
			case test.script != "":
				execution = map[string]any{
					"script": map[string]any{"path": "scripts/action.sh"},
				}
				scriptDir := filepath.Join(packDir, "scripts")
				if err := os.MkdirAll(scriptDir, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(
					filepath.Join(scriptDir, "action.sh"), []byte(test.script), 0o755,
				); err != nil {
					t.Fatal(err)
				}
			case test.program != "":
				execution = map[string]any{
					"command": map[string]any{
						"binary": "/bin/sh",
						"argv":   []string{"-c", test.program},
					},
				}
			}
			action := encodeFixtureAction(t, test.id, execution)
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), action, 0o644); err != nil {
				t.Fatal(err)
			}

			err := validatePackPipelineFailures(fixturePackActionLintInput(t, packDir))
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
		if err := validatePackPipelineFailures(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
