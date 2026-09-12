package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The shape of a real twin: the id on line 2, the cross-reference comment inside
// execution:, and one identical body. %s is the twin's id.
const packTwinFixture = `schema_version: 1
id: %s
title: Process I/O accounting
kind: exec
risk: low
description: >
  Show ` + "`/proc/<pid>/io`" + ` for one process — bytes read and written.
args:
  - name: pid
    type: integer
    required: true
execution:
  # The execution contract AND the operator-facing copy match %s —
  # same command, deadline, caps, and words, whichever pack the
  # operator installed.
  command:
    binary: cat
    argv:
      - "/proc/{{ args.pid }}/io"
  timeout: 5s
`

// writeTwins builds a throwaway packs/ tree: one pack per entry, each declaring
// one action whose body is the fixture above with the given substitutions
// applied, so a test can inject exactly one divergence.
func writeTwins(t *testing.T, packs map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for pack, body := range packs {
		dir := filepath.Join(root, "packs", pack, "actions")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		manifest := "schema_version: 1\nactions:\n  - actions/pid_io.yaml\n"
		if err := os.WriteFile(filepath.Join(root, "packs", pack, "pack.yaml"), []byte(manifest), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "pid_io.yaml"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// twin renders the fixture for one side of a pair, then applies replacements in
// pairs (old, new) to inject a divergence.
func twin(id, other string, replacements ...string) string {
	body := fmt.Sprintf(packTwinFixture, id, other)
	for index := 0; index+1 < len(replacements); index += 2 {
		body = strings.Replace(body, replacements[index], replacements[index+1], 1)
	}
	return body
}

func twinPair(t *testing.T, leftReplacements, rightReplacements []string) string {
	t.Helper()
	return writeTwins(t, map[string]string{
		"debugging":         twin("debugging.pid_io", "forensics.pid_io", leftReplacements...),
		"process-forensics": twin("forensics.pid_io", "debugging.pid_io", rightReplacements...),
	})
}

func TestCheckPackTwinActions(t *testing.T) {
	// The baseline the real tree is in: identical apart from the two exempt
	// lines, which differ in every direction (id value and named twin).
	t.Run("twins differing only on id and the reference pass", func(t *testing.T) {
		root := twinPair(t, nil, nil)
		if err := checkPackTwinActions(root, manifestsIn(t, root)); err != nil {
			t.Errorf("checkPackTwinActions = %v, want nil", err)
		}
	})

	// The defect this check exists for: an execution contract edited on one side
	// only. 60s vs 5s is the original divergence the rule was written after.
	t.Run("a diverged timeout is refused", func(t *testing.T) {
		root := twinPair(t, nil, []string{"timeout: 5s", "timeout: 60s"})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a diverged timeout")
		}
		// Reported from the lexicographically smaller id so the output is stable,
		// naming both files and both texts — that is the whole fix.
		for _, want := range []string{
			"packs/debugging/actions/pid_io.yaml",
			"packs/process-forensics/actions/pid_io.yaml",
			"twin forensics.pid_io",
			"line 20",
			"timeout: 5s",
			"timeout: 60s",
		} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error does not mention %q: %v", want, err)
			}
		}
	})

	// Operator-facing copy counts as much as the contract — it is what an LLM
	// ranks and what an operator reads before approving.
	t.Run("diverged copy is refused", func(t *testing.T) {
		root := twinPair(t, []string{"title: Process I/O accounting", "title: Process IO"}, nil)
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted diverged titles")
		}
		if !strings.Contains(err.Error(), "line 3") || !strings.Contains(err.Error(), "title: Process IO") {
			t.Errorf("error does not point at the title line: %v", err)
		}
	})

	// Wrapping is the divergence that survived two review passes, so it has to
	// fire even though the rendered prose is the same.
	t.Run("rewrapped description is refused", func(t *testing.T) {
		root := twinPair(t, nil, []string{
			"  Show `/proc/<pid>/io` for one process — bytes read and written.",
			"  Show `/proc/<pid>/io` for one process — bytes read\n  and written.",
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a rewrapped description")
		}
	})

	// A block added on one side only. It diverges against a line that exists on
	// the other side (its trailing blank), so it reports as an ordinary
	// difference rather than as a length mismatch.
	t.Run("an appended block is refused", func(t *testing.T) {
		root := twinPair(t, []string{"  timeout: 5s\n", "  timeout: 5s\noutput:\n  parser: text\n"}, nil)
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted an appended block")
		}
		if !strings.Contains(err.Error(), "output:") {
			t.Errorf("error does not report the extra content: %v", err)
		}
	})

	// The one way one twin really does run out of lines: its final newline is
	// missing, so every line matched and one file simply stops.
	t.Run("a missing final newline is refused", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging": twin("debugging.pid_io", "forensics.pid_io"),
			"process-forensics": strings.TrimSuffix(
				twin("forensics.pid_io", "debugging.pid_io"), "\n"),
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a missing final newline")
		}
		if !strings.Contains(err.Error(), "has no further lines") {
			t.Errorf("error does not report the length mismatch: %v", err)
		}
	})

	// One-sided references leave the other file unguarded, which is how a
	// reword would otherwise retire this check silently.
	t.Run("a one-sided reference is refused", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging": twin("debugging.pid_io", "forensics.pid_io"),
			"process-forensics": twin("forensics.pid_io", "debugging.pid_io",
				"copy match debugging.pid_io —", "copy matches the other pack"),
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a one-sided twin reference")
		}
		if !strings.Contains(err.Error(), "must be mutual") || !strings.Contains(err.Error(), "no twin") {
			t.Errorf("error does not report the missing back-reference: %v", err)
		}
	})

	t.Run("a reference to a third action is refused", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging":         twin("debugging.pid_io", "forensics.pid_io"),
			"process-forensics": twin("forensics.pid_io", "linux.pid_io"),
			"linux-core":        twin("linux.pid_io", "forensics.pid_io"),
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a non-mutual reference")
		}
		if !strings.Contains(err.Error(), "must be mutual") {
			t.Errorf("error does not report the mismatch: %v", err)
		}
	})

	// A typo in the named id would otherwise mean no comparison happens at all.
	t.Run("a reference to a missing action is refused", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging": twin("debugging.pid_io", "forensics.pid_iop"),
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted a reference to a missing action")
		}
		if !strings.Contains(err.Error(), "which no pack declares") {
			t.Errorf("error does not report the unresolved twin: %v", err)
		}
	})

	t.Run("an action naming itself is refused", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging": twin("debugging.pid_io", "debugging.pid_io"),
		})
		err := checkPackTwinActions(root, manifestsIn(t, root))
		if err == nil {
			t.Fatal("checkPackTwinActions accepted an action naming itself")
		}
		if !strings.Contains(err.Error(), "names itself") {
			t.Errorf("error does not report the self-reference: %v", err)
		}
	})

	// Actions that declare no twin are the overwhelming majority and must not be
	// dragged into a comparison by sharing a basename.
	t.Run("actions without a reference are not compared", func(t *testing.T) {
		plain := strings.ReplaceAll(twin("debugging.pid_io", "forensics.pid_io"),
			"  # The execution contract AND the operator-facing copy match forensics.pid_io —\n", "")
		other := strings.ReplaceAll(twin("forensics.pid_io", "debugging.pid_io"),
			"  # The execution contract AND the operator-facing copy match debugging.pid_io —\n", "")
		other = strings.Replace(other, "timeout: 5s", "timeout: 60s", 1)
		root := writeTwins(t, map[string]string{"debugging": plain, "process-forensics": other})
		if err := checkPackTwinActions(root, manifestsIn(t, root)); err != nil {
			t.Errorf("checkPackTwinActions = %v, want nil for undeclared pairs", err)
		}
	})

	// Prose that happens to contain the word "match" is not a declaration.
	t.Run("prose mentioning match is not a reference", func(t *testing.T) {
		root := writeTwins(t, map[string]string{
			"debugging": twin("debugging.pid_io", "forensics.pid_io",
				"title: Process I/O accounting",
				"title: Process I/O accounting\ndetail: must match the investigated payment."),
			"process-forensics": twin("forensics.pid_io", "debugging.pid_io",
				"title: Process I/O accounting",
				"title: Process I/O accounting\ndetail: must match the investigated payment."),
		})
		if err := checkPackTwinActions(root, manifestsIn(t, root)); err != nil {
			t.Errorf("checkPackTwinActions = %v, want nil", err)
		}
	})
}

// The committed packs must already satisfy the check — the two live pairs were
// converged by hand over three passes, and this is what holds them there.
func TestShippedPackTwinsAreIdentical(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	manifests := manifestsIn(t, root)
	if len(manifests) == 0 {
		t.Fatal("no pack manifests were found; the path is wrong")
	}
	if err := checkPackTwinActions(root, manifests); err != nil {
		t.Errorf("packs/: %v", err)
	}

	// Reworded on BOTH sides at once, the pair would stop being declared and the
	// check above would pass by finding nothing. Naming the live pairs here is
	// what makes that a failure instead.
	actions, err := loadPackTwinActions(root, manifests)
	if err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string]string{
		"debugging.pid_io":     "forensics.pid_io",
		"forensics.pid_io":     "debugging.pid_io",
		"debugging.pid_status": "forensics.pid_status",
		"forensics.pid_status": "debugging.pid_status",
	} {
		action, ok := actions[id]
		if !ok {
			t.Errorf("%s is no longer a declared action", id)
			continue
		}
		if action.twinID != want {
			t.Errorf("%s names twin %q, want %q — if the pair was retired on purpose, drop it from this list", id, action.twinID, want)
		}
	}
}
