package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackJQFilters(t *testing.T) {
	tests := []struct {
		name       string
		id         string
		program    string
		script     string
		wantErr    bool
		wantErrMsg string
	}{
		{
			name:       "inline filter calls gsub",
			id:         "fixture.inline_gsub",
			program:    "jq -nce '{clean: (env.NAME | gsub(\"[[:cntrl:]]+\"; \" \"))}'",
			wantErr:    true,
			wantErrMsg: "fixture.inline_gsub (gsub)",
		},
		{
			// gsub ends in sub; the identifier guard is what keeps one call
			// from being reported as two builtins.
			name:       "gsub is not also counted as sub",
			id:         "fixture.gsub_only",
			program:    "jq -r 'gsub(\"a\"; \"b\")'",
			wantErr:    true,
			wantErrMsg: "fixture.gsub_only (gsub)",
		},
		{
			name:       "packaged script calls test",
			id:         "fixture.script_test",
			script:     "#!/bin/sh\nnft -j list ruleset | jq -ce 'if test(\"^[0-9]+$\") then . else null end'\n",
			wantErr:    true,
			wantErrMsg: "fixture.script_test (test)",
		},
		{
			name:       "heredoc filter calls gsub",
			id:         "fixture.heredoc_gsub",
			script:     "#!/bin/sh\njq -n -f /dev/stdin <<'JQ'\ngsub(\"a\"; \"b\")\nJQ\n",
			wantErr:    true,
			wantErrMsg: "fixture.heredoc_gsub (gsub)",
		},
		{
			name:       "unquoted escaped filter calls gsub",
			id:         "fixture.escaped_gsub",
			program:    `jq -n gsub\(\"a\"\;\"b\"\)`,
			wantErr:    true,
			wantErrMsg: "fixture.escaped_gsub (gsub)",
		},
		{
			name:       "capture and match in one filter",
			id:         "fixture.capture_match",
			program:    "jq -ce 'if match(\"^x\") then capture(\"^(?<a>x)\") else . end'",
			wantErr:    true,
			wantErrMsg: "fixture.capture_match (capture, match)",
		},
		{
			name:       "scan and splits",
			id:         "fixture.scan_splits",
			program:    "jq -r '[scan(\"[0-9]+\")] + [splits(\",\")]'",
			wantErr:    true,
			wantErrMsg: "fixture.scan_splits (scan, splits)",
		},
		{
			name:       "split with a regex flags argument",
			id:         "fixture.split_two",
			program:    "jq -r 'split(\", *\"; null)'",
			wantErr:    true,
			wantErrMsg: "fixture.split_two (split/2)",
		},
		{
			name:    "core split takes one argument",
			id:      "fixture.split_one",
			program: "jq -r 'split(\".\") | .[0]'",
		},
		{
			// A nested call's own argument separator is not this call's.
			name:    "a semicolon below the top level is not split/2",
			id:      "fixture.split_nested",
			program: "jq -r 'split(clipped(48; 48))'",
		},
		{
			name:    "shell comments are not scanned",
			id:      "fixture.shell_comment",
			program: "# spelled without test() and gsub(...) for the jq build\njq -r '.name'",
		},
		{
			name:   "jq comments inside a single-quoted program are not scanned",
			id:     "fixture.jq_comment",
			script: "#!/bin/bash\njq -nce '\n  # the obvious spelling, gsub(\"[[:cntrl:]]+\"; \" \"), needs Oniguruma\n  def clean: explode | implode;\n  {name: (env.NAME | clean)}\n'\n",
		},
		{
			// The # belongs to the string, so nothing after it may be skipped:
			// the gsub on the next line still has to be found.
			name:       "a hash inside a jq string does not start a comment",
			id:         "fixture.hash_in_string",
			program:    "jq -nce '($header[\"x5t#S256\"] // null) as $thumbprint | {t: ($thumbprint | gsub(\"a\"; \"b\"))}'",
			wantErr:    true,
			wantErrMsg: "fixture.hash_in_string (gsub)",
		},
		{
			name:    "awk has its own sub and match",
			id:      "fixture.awk_program",
			program: "ps -eo pid=,comm= | awk '{ $1=\"\"; sub(/^ +/, \"\"); if (match($0, /x/)) print }'",
		},
		{
			name:    "sed and perl programs are skipped too",
			id:      "fixture.sed_perl",
			program: "cat /etc/hosts | sed 's/sub(x)/y/' | perl -pe 'sub { 1 }'",
		},
		{
			// The skip ends with awk's pipeline segment: a jq filter later in
			// the same program is still checked.
			name:       "a jq filter after an awk program is still checked",
			id:         "fixture.awk_then_jq",
			program:    "ps -eo pid= | awk '{ sub(/^ +/, \"\") }' | jq -R '[., gsub(\"a\"; \"b\")]'",
			wantErr:    true,
			wantErrMsg: "fixture.awk_then_jq (gsub)",
		},
		{
			name:   "core-jq spellings pass",
			id:     "fixture.core_only",
			script: "#!/bin/bash\njq -nce '\n  def all_digits: length > 0 and (explode | all(.[]; . >= 48 and . <= 57));\n  def clean: ascii_downcase | contains(\"restart\");\n  {ok: (env.NAME | ltrimstr(\"x\") | split(\"@\") | .[0] | all_digits)}\n'\n",
		},
		{
			// A bash pattern escapes a literal quote. Reading that as an
			// opening quote inverts the quoting of the whole rest of the
			// script, and every filter below it goes unseen.
			name:       "an escaped quote does not invert the quoting",
			id:         "fixture.escaped_quote",
			script:     "#!/bin/bash\n[[ \"$1\" =~ ^[A-Za-z0-9._~!$\\&\\'\\(\\)]+$ ]] || exit 1\njq -r 'gsub(\"a\"; \"b\")'\n",
			wantErr:    true,
			wantErrMsg: "fixture.escaped_quote (gsub)",
		},
		{
			name:    "shell test is not the jq builtin",
			id:      "fixture.shell_test",
			program: "test -r \"$1\" || exit 1\njq -r '.value' \"$1\"",
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

			err := validatePackJQFilters(fixturePackActionLintInput(t, packDir))
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

func TestJQLintCoversTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackJQFilters(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
