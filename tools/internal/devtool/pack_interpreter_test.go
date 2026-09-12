package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writePackInterpreterFixture(t *testing.T, manifest string, actions map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range actions {
		if err := os.WriteFile(filepath.Join(dir, "actions", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const bashAction = `id: p.a
execution:
  script:
    path: scripts/a.sh
    interpreter: /bin/bash
`

const shAction = `id: p.b
execution:
  script:
    path: scripts/b.sh
    interpreter: /bin/sh
`

func TestValidatePackInterpreterBinaries_FlagsUndeclaredBash(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"a.yaml": bashAction})

	err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir))
	if err == nil {
		t.Fatal("an action running /bin/bash with bash undeclared must fail")
	}
	if !strings.Contains(err.Error(), "bash") || !strings.Contains(err.Error(), "a.yaml") {
		t.Fatalf("error should name the binary and the action file, got %v", err)
	}
}

func TestValidatePackInterpreterBinaries_AcceptsDeclaredBash(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n    - bash\n",
		map[string]string{"a.yaml": bashAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "bash")); err != nil {
		t.Fatalf("declared bash should pass, got %v", err)
	}
}

// /bin/sh is on every host we support, so it is not a declarable dependency —
// requiring it would put noise in 178 actions and teach nothing.
func TestValidatePackInterpreterBinaries_PosixShellNeedsNoDeclaration(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"b.yaml": shAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir)); err != nil {
		t.Fatalf("/bin/sh should need no declaration, got %v", err)
	}
}

const execAction = `id: p.c
execution:
  command:
    binary: smartctl
    argv: ["--scan"]
`

const coreutilAction = `id: p.d
execution:
  command:
    binary: cat
    argv: ["/proc/meminfo"]
`

const absoluteAction = `id: p.e
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "echo hi"]
`

// The exec half of the same gap: `emisar pack info` LookPaths exactly what
// requires.binaries names, so an undeclared smartctl fails at dispatch with no
// pre-flight signal. Eighteen packs sat here.
func TestValidatePackInterpreterBinaries_FlagsUndeclaredExecBinary(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"c.yaml": execAction})

	err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "curl"))
	if err == nil || !strings.Contains(err.Error(), "smartctl") || !strings.Contains(err.Error(), "c.yaml") {
		t.Fatalf("error should name the binary and the action file, got %v", err)
	}
}

func TestValidatePackInterpreterBinaries_AcceptsDeclaredExecBinary(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - smartctl\n",
		map[string]string{"c.yaml": execAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "smartctl")); err != nil {
		t.Fatalf("declared smartctl should pass, got %v", err)
	}
}

// Coreutils are on every host, and /bin/sh is the one sanctioned absolute
// path — declaring either would be noise in hundreds of actions.
func TestValidatePackInterpreterBinaries_UbiquitousAndAbsoluteBinariesAreExempt(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"d.yaml": coreutilAction, "e.yaml": absoluteAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "curl")); err != nil {
		t.Fatalf("coreutils and /bin/sh should need no declaration, got %v", err)
	}
}

const jqScriptAction = `id: p.jq
execution:
  script:
    path: scripts/jq.sh
    interpreter: /bin/bash
`

const jqInlineAction = `id: p.inline
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "docker compose ls --format json | jq -ce '.[] | .Name'"]
`

// The third face of the gap: a helper the script text itself runs. Every case
// pins the packaged-script or inline-program text, because that is the only
// place this dependency is written down.
func TestValidatePackScriptHelperBinaries(t *testing.T) {
	tests := []struct {
		name     string
		declared []string
		action   string
		script   string
		wantFail bool
	}{
		{
			name:     "undeclared jq in a packaged script",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\ndocker ps --format json | jq -ce .\n",
			wantFail: true,
		},
		{
			name:     "declared jq passes",
			declared: []string{"bash", "jq"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\ndocker ps --format json | jq -ce .\n",
		},
		// The scripts that run jq are also the ones that explain it, so a
		// comment naming it is not a dependency: docker.compose_config carries
		// three, one of them about a builtin it deliberately avoids.
		{
			name:     "a commented mention is not a dependency",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"# Spelled without jq so it runs on a host that has none.\n" +
				"docker ps --format '{{.Names}}'\n",
		},
		// And the comment skipping must not hide the invocation beside it.
		{
			name:     "a commented mention beside a real call still fires",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"# gsub needs Oniguruma, which jq's minimal build omits.\n" +
				"docker ps --format json | jq -ce .\n",
			wantFail: true,
		},
		// A word-boundary match, so a variable that merely carries the name is
		// not an invocation.
		{
			name:     "a name that only appears inside an identifier is not a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\njq_filter=.Names\nprintf '%s\\n' \"$jq_filter\"\n",
		},
		{
			name:     "undeclared jq in an inline -c program",
			declared: []string{"docker"},
			action:   jqInlineAction,
			wantFail: true,
		},
		// The diagnostic an action prints when a helper is MISSING is the one
		// place the name is guaranteed to appear without being run, quoted or
		// bare. Both spellings invoke only printf.
		{
			name:     "a quoted diagnostic argument naming the helper is not a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"if ! command -v docker >/dev/null; then\n" +
				"  printf '%s\\n' \"jq unavailable\" >&2\n  exit 1\nfi\n" +
				"docker ps --format '{{.Names}}'\n",
		},
		{
			name:     "a bare argument naming the helper is not a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\nprintf 'missing: %s\\n' jq >&2\nexit 1\n",
		},
		// A command substitution inside a double-quoted word is a real command
		// scope, so attribution has to survive it — this is what a fix that
		// skipped every double-quoted span would lose.
		{
			name:     "a command substitution inside a double-quoted word still fires",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"detail=\"$(jq -r '.error.message' \"$response\")\"\nprintf '%s\\n' \"$detail\"\n",
			wantFail: true,
		},
		{
			name:     "a quoted command word is still a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\ndocker ps --format json | 'jq' -ce .\n",
			wantFail: true,
		},
		{
			name:     "a call led by an assignment prefix is still a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\nJQ_COLORS=0 jq -nce '{ok: true}'\n",
			wantFail: true,
		},
		{
			name:     "a call after a shell keyword is still a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script:   "#!/bin/bash\nset -euo pipefail\nif ! jq -e . plan.json; then exit 1; fi\n",
			wantFail: true,
		},
		// A backtick substitution is a command scope like `$( … )`, so its
		// CLOSING backtick has to end that scope instead of opening a second
		// one: otherwise every word after the span reads as a fresh command and
		// the diagnostic argument beside it is attributed.
		{
			name:     "an argument after a closed backtick substitution is not a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"if ! command -v docker >/dev/null; then\n" +
				"  printf '%s missing: %s\\n' `date -u +%FT%TZ` jq >&2\n  exit 1\nfi\n" +
				"docker ps --format '{{.Names}}'\n",
		},
		{
			name:     "jq inside a backtick substitution is a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"names=`jq -r '.[].Name' plan.json`\nprintf '%s\\n' \"$names\"\n",
			wantFail: true,
		},
		{
			name:     "jq inside a double-quoted backtick substitution is a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"detail=\"`jq -r '.error.message' \"$response\"`\"\nprintf '%s\\n' \"$detail\"\n",
			wantFail: true,
		},
		// And closing the scope must restore the SURROUNDING position, not swallow
		// the rest of the program: the call on the next line still counts.
		{
			name:     "a call after a closed backtick substitution is still a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"stamp=`date -u +%FT%TZ`\n" +
				"docker ps --format json | jq -ce --arg at \"$stamp\" .\n",
			wantFail: true,
		},
		// The name inside a single-quoted jq filter, and the filter text the
		// catalog actually ships, are not invocations.
		{
			name:     "filter text naming the helper is not a call",
			declared: []string{"bash"},
			action:   jqScriptAction,
			script: "#!/bin/bash\nset -euo pipefail\n" +
				"awk '{print $1}' hosts.txt | sed 's/jq/json/'\n",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := writePackInterpreterFixture(t, "", map[string]string{"a.yaml": test.action})
			if test.script != "" {
				writePackActionLintFile(t, dir, "scripts/jq.sh", test.script)
			}

			err := validatePackScriptHelperBinaries(
				fixturePackActionLintInput(t, dir, test.declared...))
			if !test.wantFail {
				if err != nil {
					t.Fatalf("want no finding, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("an action running jq with jq undeclared must fail")
			}
			if !strings.Contains(err.Error(), "jq") ||
				!strings.Contains(err.Error(), "requires.binaries") {
				t.Fatalf("error should name the binary and the manifest key, got %v", err)
			}
		})
	}
}

func TestScriptHelperBinaryLintCoversTheShippedCatalog(t *testing.T) {
	packDirs := shippedPackDirs(t)
	for _, packDir := range packDirs {
		if err := validatePackScriptHelperBinaries(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}

	// A check that detects nothing would pass the catalog too, so prove it
	// actually reads the shipped script text: with the declarations ignored, the
	// packs that run jq must ALL be flagged. 28 do — 27 declared it before this
	// check existed and docker is the one that did not.
	flagged := 0
	for _, packDir := range packDirs {
		input := mustLoadPackActionLintInput(t, packDir)
		input.requiredBinaries = map[string]bool{}
		if err := validatePackScriptHelperBinaries(input); err != nil {
			flagged++
		}
	}
	if flagged < 28 {
		t.Errorf("detected jq in %d packs, want at least the 28 that run it", flagged)
	}
}

func shippedPackDirs(t *testing.T) []string {
	t.Helper()
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	dirs := make([]string, 0, len(manifests))
	for _, manifest := range manifests {
		dirs = append(dirs, filepath.Dir(manifest))
	}
	return dirs
}

func TestExecBinaryLintCoversTheShippedCatalog(t *testing.T) {
	for _, packDir := range shippedPackDirs(t) {
		if err := validatePackInterpreterBinaries(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
