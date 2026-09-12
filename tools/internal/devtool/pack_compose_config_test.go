package devtool

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// docker.compose_config is the catalog's one action whose safety lives in shell
// control flow rather than in its argv, so it gets a test that actually runs
// the script. Two regressions have already shipped in these fifteen lines:
//
//   - every section was captured in a helper reached through `$( )`, where bash
//     does not inherit `errexit`, so a failed `docker compose config` in any
//     call after the leading `--quiet` parse was discarded and the action
//     answered `{"valid": true, "services": []}` with exit 0 — a false
//     all-clear on a low, no-approval read;
//   - fixing that by capturing each section whole made the operator's file the
//     size of this shell's heap, and it put the bound on bash's *character*
//     count of a value command substitution had already stripped the trailing
//     newline from, so a 65,537-byte section ending in a newline and a 65,538-
//     byte section of two-byte characters both passed the 64 KiB bound;
//   - and bounding it again with `head -c … | cat >/dev/null` put two more
//     commands inside that same `$( )`, where a failure of either was dropped
//     on the floor by the `printf` that follows them: the reader's status never
//     reached the pipeline, so `pipefail` reported the producer's 0 and the
//     action answered `{"valid": true, "services": []}` with exit 0 again.
//
// The behavior plan in packs/docker/test/cases.yaml covers the overflow refusal
// against a real daemon. It cannot reach these rows: no Compose file makes a
// later `docker compose config` call fail while the preflight parse succeeds,
// none makes `head` or the drain fail at all, and byte-exact boundary and
// multibyte sections are not something a fixture file can dictate. The stub
// producer is the seam for the first two, and the stub readers below for the
// third.
const composeConfigStubDocker = `#!/bin/bash
set -uo pipefail
what=other
case " $* " in
  *" --quiet "*) what=quiet ;;
  *" --services "*) what=services ;;
  *" --networks "*) what=networks ;;
  *" --volumes "*) what=volumes ;;
  *" json "*) what=json ;;
esac
if [ "$what" = "${STUB_FAIL_AT:-none}" ]; then
  printf 'stub: %s failed\n' "$what" >&2
  exit "${STUB_RC:-1}"
fi
case $what in
  quiet) ;;
  services)
    if [ -n "${STUB_SERVICES_FILE:-}" ]; then exec cat "$STUB_SERVICES_FILE"; fi
    printf 'web\napi\n'
    ;;
  networks) printf 'default\n' ;;
  volumes) printf 'data\n' ;;
  json)
    if [ -n "${STUB_JSON_FILE:-}" ]; then exec cat "$STUB_JSON_FILE"; fi
    printf '%s\n' '{"services":{"web":{"image":"busybox:1.36","profiles":["edge"]},"api":{"image":"nginx:1.27"}}}'
    ;;
esac
`

// The reader stubs. Each is installed only for the row that injects into it, so
// no other row pays an extra process per capture — which the RLIMIT_AS row in
// particular could not afford.
//
// Each one has to fail NARROWLY. `cat` is both the drain and how the producer
// above prints a section from a file, and `jq` is both the list filter and the
// closing summary; a stub that failed every call would prove the script notices
// a broken PATH rather than that it carries a reader's status out of the
// capture. So the drain is the argument-less `cat`, and the list filter is the
// `jq -r`; everything else execs the real binary.
const (
	composeConfigStubHead = `#!/bin/bash
if [ -n "${STUB_HEAD_RC:-}" ]; then
  printf 'stub: head failed\n' >&2
  exit "$STUB_HEAD_RC"
fi
exec %s "$@"
`
	composeConfigStubCat = `#!/bin/bash
if [ -n "${STUB_CAT_RC:-}" ] && [ "$#" -eq 0 ]; then
  printf 'stub: drain failed\n' >&2
  exit "$STUB_CAT_RC"
fi
exec %s "$@"
`
	composeConfigStubJq = `#!/bin/bash
for arg in "$@"; do
  if [ -n "${STUB_JQ_RC:-}" ] && [ "$arg" = "-r" ]; then
    printf 'stub: jq failed\n' >&2
    exit "$STUB_JQ_RC"
  fi
done
exec %s "$@"
`
)

// The bound the script enforces, and the message it owes the operator.
const (
	composeConfigSectionBound = 65536
	composeConfigOverflowText = "Compose config summary section exceeded 64 KiB"
)

// The multibyte rows below are only a guard under a multibyte locale: in the C
// locale a character IS a byte, so bash's `${#value}` agrees with `wc -c` and a
// regression to character counting would pass. Every run therefore names one.
func composeConfigLocale() string {
	if runtime.GOOS == "darwin" {
		return "en_US.UTF-8"
	}
	return "C.UTF-8"
}

// And the locale has to actually take, or the rows above stop checking quietly.
func TestComposeConfigTestLocaleCountsCharacters(t *testing.T) {
	cmd := exec.Command("bash", "-c", `v=é; printf '%s' "${#v}"`)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=" + composeConfigLocale()}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("locale probe: %v", err)
	}
	if got := string(out); got != "1" {
		t.Fatalf("bash under LC_ALL=%s measured a two-byte character as %s bytes; the "+
			"multibyte section rows cannot distinguish a byte bound from a character "+
			"bound without a multibyte locale", composeConfigLocale(), got)
	}
}

func TestDockerComposeConfigPropagatesLaterCallFailures(t *testing.T) {
	tests := []struct {
		name string
		env  []string
		exit int
	}{
		// The leading `compose_config --quiet` is the only call that runs
		// outside a helper, so it is the only one `set -e` ever covered.
		{name: "preflight parse", env: []string{"STUB_FAIL_AT=quiet", "STUB_RC=3"}, exit: 3},
		{name: "later --services call", env: []string{"STUB_FAIL_AT=services", "STUB_RC=3"}, exit: 3},
		{name: "later --networks call", env: []string{"STUB_FAIL_AT=networks", "STUB_RC=2"}, exit: 2},
		{name: "later --volumes call", env: []string{"STUB_FAIL_AT=volumes", "STUB_RC=4"}, exit: 4},
		{name: "later --format json call", env: []string{"STUB_FAIL_AT=json", "STUB_RC=5"}, exit: 5},
		// 141 is the filed symptom: the producer killed by a reader that closed
		// the pipe. The drain is what keeps it from happening on a good parse,
		// and a producer that really does die that way still has to be reported.
		{name: "producer killed by SIGPIPE", env: []string{"STUB_FAIL_AT=services", "STUB_RC=141"}, exit: 141},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			run := runComposeConfig(t, test.env, 0)
			if run.exit != test.exit {
				t.Fatalf("exit = %d, want %d (stderr %q)", run.exit, test.exit, run.stderr)
			}
			if strings.Contains(run.stdout, "valid") {
				t.Fatalf("a failed source still produced a summary: %q", run.stdout)
			}
		})
	}
}

// The producer is not the only thing in a capture that can fail. `head`, the
// drain and the list `jq` all run inside the same command substitution, and a
// failure of any of them means the script does not have the section it is about
// to summarize — so it owes the operator that status, not a summary. Only `jq`
// gets this for free: it is a pipeline element, so `pipefail` carries it. The
// reader and the drain are commands INSIDE the last element, and what they
// return is whatever the function chose to return after them.
func TestDockerComposeConfigPropagatesReaderFailures(t *testing.T) {
	tests := []struct {
		name string
		env  []string
		exit int
	}{
		// Left uncarried this is the worst row of the three: the capture is
		// empty, the sentinel still marks it complete, an empty section is
		// under the bound, and the operator reads `valid: true` with no
		// services as "this stack parses and declares nothing".
		{name: "bounded reader", env: []string{"STUB_HEAD_RC=7"}, exit: 7},
		// The drain runs after the reader already succeeded, so the capture is
		// intact and only the producer's own exit is lost. Still a failure: the
		// script cannot tell whether the producer finished or died behind it.
		{name: "drain", env: []string{"STUB_CAT_RC=9"}, exit: 9},
		// The second producer in the JSON helper's pipe. `pipefail` covers this
		// one, and the row is here so a future reader fix cannot swallow it on
		// the way past — the reader returning 0 for jq's failure is exactly the
		// shape that hid the two above.
		{name: "list jq", env: []string{"STUB_JQ_RC=6"}, exit: 6},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			run := runComposeConfig(t, test.env, 0)
			if run.exit != test.exit {
				t.Fatalf("exit = %d, want %d (stderr %q)", run.exit, test.exit, run.stderr)
			}
			if strings.Contains(run.stdout, "valid") {
				t.Fatalf("a failed capture still produced a summary: %q", run.stdout)
			}
		})
	}
}

func TestDockerComposeConfigBoundsSectionsByBytes(t *testing.T) {
	bound := composeConfigSectionBound
	tests := []struct {
		name string
		// section is the exact byte stream the stub prints for --services.
		section []byte
		// json replaces the stub's `--format json` document instead.
		json    []byte
		exit    int
		refused bool
	}{
		{
			name:    "one line at the bound",
			section: composeConfigSection(bound, "n", ""),
			exit:    0,
		},
		{
			name:    "one line one byte past the bound",
			section: composeConfigSection(bound+1, "n", ""),
			exit:    1,
			refused: true,
		},
		{
			// What the real producer emits: many lines, last byte a newline.
			name:    "many lines at the bound",
			section: composeConfigSection(bound, strings.Repeat("n", 63)+"\n", ""),
			exit:    0,
		},
		{
			// Command substitution strips the trailing newline, so measuring
			// the captured value alone reads 65,536 here and passes.
			name:    "one byte past the bound, ending in a newline",
			section: composeConfigSection(bound+1, "n", "\n"),
			exit:    1,
			refused: true,
		},
		{
			// `$( )` strips a whole trailing run, not just one newline.
			name:    "four bytes past the bound, ending in four newlines",
			section: composeConfigSection(bound+4, "n", "\n\n\n\n"),
			exit:    1,
			refused: true,
		},
		{
			name:    "multibyte section at the bound",
			section: composeConfigSection(bound, "é", ""),
			exit:    0,
		},
		{
			// 32,769 characters, 65,538 bytes: `${#value}` counts the former.
			name:    "multibyte section past the bound",
			section: composeConfigSection(bound+2, "é", ""),
			exit:    1,
			refused: true,
		},
		{
			// The JSON-list helper has its own capture, and jq -r output is a
			// second producer between `docker` and the bound.
			name:    "json profile section past the bound",
			json:    composeConfigProfilesJSON(bound + 4096),
			exit:    1,
			refused: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var env []string
			if test.section != nil {
				env = append(env, "STUB_SERVICES_FILE="+composeConfigTempFile(t, "services", test.section))
			}
			if test.json != nil {
				env = append(env, "STUB_JSON_FILE="+composeConfigTempFile(t, "config.json", test.json))
			}
			run := runComposeConfig(t, env, 0)
			if run.exit != test.exit {
				t.Fatalf("exit = %d, want %d (stderr %q)", run.exit, test.exit, run.stderr)
			}
			if test.refused {
				if !strings.Contains(run.stderr, composeConfigOverflowText) {
					t.Fatalf("stderr = %q, want the authored size message", run.stderr)
				}
				if strings.Contains(run.stdout, "valid") {
					t.Fatalf("an over-bound section still produced a summary: %q", run.stdout)
				}
				return
			}
			if !strings.Contains(run.stdout, `"valid":true`) {
				t.Fatalf("stdout = %q, want a summary (stderr %q)", run.stdout, run.stderr)
			}
		})
	}
}

// What the shell holds per section has to be the bound, not the producer's
// output: a real stack's `docker compose config` is as large as the operator's
// file, and capturing it whole ended the action on bash's own
// "xrealloc: cannot allocate" instead of the authored size message.
func TestDockerComposeConfigRetainsOnlyTheBound(t *testing.T) {
	const sectionBytes = 64 << 20
	section := composeConfigSection(sectionBytes, strings.Repeat("n", 79)+"\n", "")
	env := []string{"STUB_SERVICES_FILE=" + composeConfigTempFile(t, "huge-services", section)}
	// RLIMIT_AS is the only portable-enough way to assert the retention rather
	// than the refusal, and Darwin does not enforce it. The refusal itself is
	// checked everywhere; CI is Linux, so the cap is enforced where it counts.
	capKiB := 0
	if runtime.GOOS == "linux" {
		capKiB = 32 << 10
	}
	run := runComposeConfig(t, env, capKiB)
	if run.exit != 1 {
		t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
	}
	if !strings.Contains(run.stderr, composeConfigOverflowText) {
		t.Fatalf("stderr = %q, want the authored size message", run.stderr)
	}
}

type composeConfigRun struct {
	stdout string
	stderr string
	exit   int
}

// runComposeConfig executes the packaged script with the stub `docker` first on
// PATH. capKiB, when non-zero, caps the script's address space so a capture
// that grows with the producer cannot complete.
func runComposeConfig(t *testing.T, env []string, capKiB int) composeConfigRun {
	t.Helper()
	script := filepath.Join("..", "..", "..", "packs", "docker", "scripts", "compose_config.sh")
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("packaged script: %v", err)
	}
	return runPackagedComposeScript(t, script, composeConfigStubDocker, []readerStub{
		{"STUB_HEAD_RC=", "head", composeConfigStubHead},
		{"STUB_CAT_RC=", "cat", composeConfigStubCat},
		{"STUB_JQ_RC=", "jq", composeConfigStubJq},
	}, env, capKiB)
}

// readerStub names the injection variable that switches a reader stub on, the
// binary it shadows, and its body — a printf template taking the real binary's
// absolute path.
type readerStub struct{ variable, name, stub string }

// runPackagedComposeScript runs one of the docker pack's packaged scripts with
// the stub `docker` first on PATH, under the multibyte locale the byte-bound
// rows need. A row that names a reader's injection variable in env also gets
// that reader stubbed ahead of the real binary; every other row runs against
// the real ones, so no row pays an extra process per capture it did not ask
// for — which the RLIMIT_AS rows in particular could not afford.
func runPackagedComposeScript(t *testing.T, script, producerStub string, readers []readerStub, env []string, capKiB int) composeConfigRun {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(producerStub), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, reader := range readers {
		if !composeConfigEnvHas(env, reader.variable) {
			continue
		}
		// The stub execs the real binary by absolute path: it is first on the
		// script's PATH, so resolving the name again would find itself.
		real, err := exec.LookPath(reader.name)
		if err != nil {
			t.Fatalf("locate %s: %v", reader.name, err)
		}
		body := fmt.Sprintf(reader.stub, real)
		if err := os.WriteFile(filepath.Join(bin, reader.name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	var cmd *exec.Cmd
	if capKiB > 0 {
		cmd = exec.Command("bash", "-c",
			fmt.Sprintf("ulimit -v %d; exec bash \"$1\" \"$2\"", capKiB),
			filepath.Base(script), script, "/opt/stack/docker-compose.yml")
	} else {
		cmd = exec.Command("bash", script, "/opt/stack/docker-compose.yml")
	}
	cmd.Env = append(env,
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"LC_ALL="+composeConfigLocale())
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	run := composeConfigRun{stdout: stdout.String(), stderr: stderr.String()}
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		run.exit = exitErr.ExitCode()
	default:
		t.Fatalf("run script: %v", err)
	}
	return run
}

func composeConfigEnvHas(env []string, prefix string) bool {
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return true
		}
	}
	return false
}

// composeConfigSection builds exactly total bytes: unit repeated and truncated
// to fit, then tail verbatim, so the section's last byte is the caller's.
func composeConfigSection(total int, unit, tail string) []byte {
	section := make([]byte, 0, total)
	for len(section) < total-len(tail) {
		section = append(section, unit...)
	}
	return append(section[:total-len(tail)], tail...)
}

// composeConfigProfilesJSON is a config document whose profile names alone pass
// bytes once jq -r has printed them one per line.
func composeConfigProfilesJSON(bytesWanted int) []byte {
	var profiles []string
	for size := 0; size < bytesWanted; {
		name := fmt.Sprintf("profile-%04d-%s", len(profiles), strings.Repeat("p", 180))
		profiles = append(profiles, `"`+name+`"`)
		size += len(name) + 1
	}
	return []byte(`{"services":{"web":{"image":"busybox:1.36","profiles":[` +
		strings.Join(profiles, ",") + `]}}}` + "\n")
}

func composeConfigTempFile(t *testing.T, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}
