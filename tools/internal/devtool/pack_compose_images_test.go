package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// docker.compose_images is the pack's second action whose safety lives in shell
// control flow rather than in its argv, and it shipped both of the failures
// compose_config already paid for:
//
//   - `head -c` closed the pipe at its limit and SIGPIPEd `docker`, so
//     `pipefail` made the capture 141 and `set -e` ended the script AT the
//     assignment — the authored "exceeded 512 KiB" refusal never ran and an
//     operator got a bare 141 with nothing on stderr, on a low, no-approval
//     read;
//   - and the bound was checked with `${#images}`, bash's CHARACTER count of a
//     value `$( )` had already stripped the trailing newline from, so a
//     524,289-byte inventory ending in a newline measured 524,288 and passed,
//     as did a multibyte inventory twice the bound.
//
// The behavior plan in packs/docker/test/cases.yaml cannot reach any of this: a
// real daemon would need thousands of created containers to print half a
// megabyte of inventory, nothing makes `head` or the drain fail, and byte-exact
// boundary and multibyte inventories are not something a Compose file can
// dictate. The stub producer is the seam for the sizes, the stub readers for
// the rest.
const composeImagesStubDocker = `#!/bin/bash
set -uo pipefail
case " $* " in
  *" images "*) ;;
  *) printf 'stub: unexpected argv: %s\n' "$*" >&2; exit 90 ;;
esac
if [ -n "${STUB_RC:-}" ]; then
  printf 'stub: docker compose images failed\n' >&2
  exit "$STUB_RC"
fi
if [ -n "${STUB_INVENTORY_FILE:-}" ]; then exec cat "$STUB_INVENTORY_FILE"; fi
printf '%s\n' '[{"ID":"sha256:aa","ContainerName":"stack-web-1","Repository":"busybox","Tag":"1.36","Size":1}]'
`

// The reader stubs, installed only for the row that injects into them so no
// other row pays an extra process per capture. Each fails NARROWLY: `cat` is
// both the drain and how the producer above prints an inventory from a file, so
// the drain is the argument-less `cat` and everything else execs the real
// binary. A stub that failed every call would prove the script notices a broken
// PATH rather than that it carries a reader's status out of the capture.
const (
	composeImagesStubHead = `#!/bin/bash
if [ -n "${STUB_HEAD_RC:-}" ]; then
  printf 'stub: head failed\n' >&2
  exit "$STUB_HEAD_RC"
fi
exec %s "$@"
`
	composeImagesStubCat = `#!/bin/bash
if [ -n "${STUB_CAT_RC:-}" ] && [ "$#" -eq 0 ]; then
  printf 'stub: drain failed\n' >&2
  exit "$STUB_CAT_RC"
fi
exec %s "$@"
`
)

// The bound the script enforces, and the message it owes the operator.
const (
	composeImagesBound        = 524288
	composeImagesOverflowText = "Compose image inventory exceeded 512 KiB"
)

// The filed symptom, and the one row a smaller over-bound inventory cannot
// reproduce: `head -c` only SIGPIPEs the producer when the producer still has
// something to write after the bound. At exactly bound+1 the reader consumes
// the whole document and exits cleanly, so every boundary row below would pass
// against the broken script too.
func TestDockerComposeImagesRefusesAnOversizedInventoryInsteadOf141(t *testing.T) {
	inventory := composeImagesInventory(700<<10, "n", "\n")
	env := []string{"STUB_INVENTORY_FILE=" + composeConfigTempFile(t, "inventory.json", inventory)}
	run := runComposeImages(t, env, 0)
	if run.exit == 141 {
		t.Fatalf("the producer was SIGPIPEd and its 141 reported as the action's status; "+
			"the drain is missing (stderr %q)", run.stderr)
	}
	if run.exit != 1 {
		t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
	}
	if !strings.Contains(run.stderr, composeImagesOverflowText) {
		t.Fatalf("stderr = %q, want the authored size message", run.stderr)
	}
	if run.stdout != "" {
		t.Fatalf("an over-bound inventory still produced a projection: %q", run.stdout)
	}
}

// A producer that genuinely fails — including one that genuinely dies of
// SIGPIPE behind something else — still has to fail the action rather than
// project an empty inventory. `[]` and "the daemon did not answer" are opposite
// facts about a stack and must not share a result.
func TestDockerComposeImagesPropagatesProducerFailures(t *testing.T) {
	for _, test := range []struct {
		name string
		exit int
	}{
		{name: "daemon unreachable", exit: 1},
		{name: "compose error", exit: 3},
		{name: "producer really killed by SIGPIPE", exit: 141},
	} {
		t.Run(test.name, func(t *testing.T) {
			run := runComposeImages(t, []string{fmt.Sprintf("STUB_RC=%d", test.exit)}, 0)
			if run.exit != test.exit {
				t.Fatalf("exit = %d, want %d (stderr %q)", run.exit, test.exit, run.stderr)
			}
			if strings.Contains(run.stdout, "[") {
				t.Fatalf("a failed source still produced a projection: %q", run.stdout)
			}
		})
	}
}

// The producer is not the only thing in the capture that can fail. `head` and
// the drain run INSIDE the last pipeline element, so `pipefail` never sees
// them: what the capture returns is whatever the function chose to return after
// them. Left uncarried, a failed reader leaves an empty capture that the
// sentinel still marks complete, and the action answers `[]` with exit 0 — a
// false all-clear about which images a stack is running.
func TestDockerComposeImagesPropagatesReaderFailures(t *testing.T) {
	for _, test := range []struct {
		name string
		env  []string
		exit int
	}{
		{name: "bounded reader", env: []string{"STUB_HEAD_RC=7"}, exit: 7},
		// The drain runs after the reader already succeeded, so the capture is
		// intact and only the producer's own exit is lost. Still a failure: the
		// script cannot tell whether the producer finished or died behind it.
		{name: "drain", env: []string{"STUB_CAT_RC=9"}, exit: 9},
	} {
		t.Run(test.name, func(t *testing.T) {
			run := runComposeImages(t, test.env, 0)
			if run.exit != test.exit {
				t.Fatalf("exit = %d, want %d (stderr %q)", run.exit, test.exit, run.stderr)
			}
			if strings.Contains(run.stdout, "[") {
				t.Fatalf("a failed capture still produced a projection: %q", run.stdout)
			}
		})
	}
}

func TestDockerComposeImagesBoundsTheInventoryByBytes(t *testing.T) {
	bound := composeImagesBound
	for _, test := range []struct {
		name      string
		inventory []byte
		refused   bool
	}{
		{
			name:      "at the bound",
			inventory: composeImagesInventory(bound, "n", ""),
		},
		{
			// What the real producer emits: a document ending in a newline.
			name:      "at the bound, ending in a newline",
			inventory: composeImagesInventory(bound, "n", "\n"),
		},
		{
			name:      "one byte past the bound",
			inventory: composeImagesInventory(bound+1, "n", ""),
			refused:   true,
		},
		{
			// Command substitution strips the trailing newline, so measuring
			// the captured value alone reads 524,288 here and passes.
			name:      "one byte past the bound, ending in a newline",
			inventory: composeImagesInventory(bound+1, "n", "\n"),
			refused:   true,
		},
		{
			// `$( )` strips a whole trailing run, not just one newline.
			name:      "four bytes past the bound, ending in four newlines",
			inventory: composeImagesInventory(bound+4, "n", "\n\n\n\n"),
			refused:   true,
		},
		{
			name:      "multibyte inventory at the bound",
			inventory: composeImagesInventory(bound, "é", "\n"),
		},
		{
			// 262,145 characters, 524,290 bytes: `${#images}` counts the former.
			name:      "multibyte inventory past the bound",
			inventory: composeImagesInventory(bound+2, "é", "\n"),
			refused:   true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			env := []string{"STUB_INVENTORY_FILE=" + composeConfigTempFile(t, "inventory.json", test.inventory)}
			run := runComposeImages(t, env, 0)
			if test.refused {
				if run.exit != 1 {
					t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
				}
				if !strings.Contains(run.stderr, composeImagesOverflowText) {
					t.Fatalf("stderr = %q, want the authored size message", run.stderr)
				}
				if run.stdout != "" {
					t.Fatalf("an over-bound inventory still produced a projection: %q", run.stdout)
				}
				return
			}
			if run.exit != 0 {
				t.Fatalf("exit = %d, want 0 (stderr %q)", run.exit, run.stderr)
			}
			if !strings.Contains(run.stdout, `"Repository"`) {
				t.Fatalf("stdout = %q, want the projected inventory (stderr %q)", run.stdout, run.stderr)
			}
		})
	}
}

// A project with no created containers is a legitimate answer, and it has to
// stay distinguishable from a failed read — which is what the capture sentinel
// buys: an empty capture and a lost one are the same string without it.
func TestDockerComposeImagesProjectsAnEmptyInventory(t *testing.T) {
	env := []string{"STUB_INVENTORY_FILE=" + composeConfigTempFile(t, "inventory.json", nil)}
	run := runComposeImages(t, env, 0)
	if run.exit != 0 {
		t.Fatalf("exit = %d, want 0 (stderr %q)", run.exit, run.stderr)
	}
	if strings.TrimSpace(run.stdout) != "[]" {
		t.Fatalf("stdout = %q, want []", run.stdout)
	}
}

// What the shell holds has to be the bound, not the producer's output: a busy
// host's inventory is as large as the number of containers Compose created, and
// capturing it whole would end the action on bash's own "xrealloc: cannot
// allocate" instead of the authored size message.
func TestDockerComposeImagesRetainsOnlyTheBound(t *testing.T) {
	inventory := composeImagesInventory(64<<20, "n", "\n")
	env := []string{"STUB_INVENTORY_FILE=" + composeConfigTempFile(t, "inventory.json", inventory)}
	// RLIMIT_AS is the only portable-enough way to assert the retention rather
	// than the refusal, and Darwin does not enforce it. The refusal itself is
	// checked everywhere; CI is Linux, so the cap is enforced where it counts.
	capKiB := 0
	if runtime.GOOS == "linux" {
		capKiB = 32 << 10
	}
	run := runComposeImages(t, env, capKiB)
	if run.exit != 1 {
		t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
	}
	if !strings.Contains(run.stderr, composeImagesOverflowText) {
		t.Fatalf("stderr = %q, want the authored size message", run.stderr)
	}
}

// runComposeImages executes the packaged script with the stub `docker` first on
// PATH, reusing the runner compose_config's rows already established: same
// address-space cap, same multibyte locale (without which a regression to
// `${#images}` would pass the rows above quietly, since in the C locale a
// character IS a byte).
func runComposeImages(t *testing.T, env []string, capKiB int) composeConfigRun {
	t.Helper()
	script := filepath.Join("..", "..", "..", "packs", "docker", "scripts", "compose_images.sh")
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("packaged script: %v", err)
	}
	return runPackagedComposeScript(t, script, composeImagesStubDocker, []readerStub{
		{"STUB_HEAD_RC=", "head", composeImagesStubHead},
		{"STUB_CAT_RC=", "cat", composeImagesStubCat},
	}, env, capKiB)
}

// composeImagesInventory builds a valid JSON inventory document of exactly
// total bytes: one row whose Repository is padded with unit and topped up with
// single-byte filler, then tail verbatim, so the document's last byte is the
// caller's.
func composeImagesInventory(total int, unit, tail string) []byte {
	const prefix = `[{"Repository":"`
	const suffix = `","Tag":"1.36"}]`
	padding := total - len(prefix) - len(suffix) - len(tail)
	if padding < 0 {
		panic("composeImagesInventory: total is smaller than the document's own syntax")
	}
	pad := make([]byte, 0, padding)
	for len(pad)+len(unit) <= padding {
		pad = append(pad, unit...)
	}
	for len(pad) < padding {
		pad = append(pad, 'n')
	}
	return []byte(prefix + string(pad) + suffix + tail)
}
