package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/executor"
)

func TestEngine_ProtectedRelativePathsNeverExecute(t *testing.T) {
	for _, operation := range []string{"read", "truncate"} {
		for _, explicitCWD := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/explicit_cwd_%t", operation, explicitCWD), func(t *testing.T) {
				state := t.TempDir()
				target := filepath.Join(state, "fixture")
				const content = "protected fixture bytes\n"
				if err := os.WriteFile(target, []byte(content), 0o600); err != nil {
					t.Fatal(err)
				}
				cwd := ""
				operand := strings.TrimPrefix(target, string(filepath.Separator))
				if explicitCWD {
					cwd = filepath.Dir(state)
					operand = filepath.Join(filepath.Base(state), "fixture")
				}
				command := "cat -- \"$1\""
				if operation == "truncate" {
					command = ": > \"$1\""
				}
				definition := fmt.Sprintf(`
schema_version: 1
id: t.protected_path
title: Protected path fixture
kind: exec
risk: medium
description: Exercise a path operand without declared path rules.
side_effects: [fixture access]
args:
  - name: path
    type: string
    required: true
    validation:
      pattern: '^[A-Za-z0-9._/-]{1,512}$'
execution:
  cwd: %q
  command:
    binary: /bin/sh
    argv: ['-c', %q, fixture, '{{ args.path }}']
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`, cwd, command)
				e, journal, root := setupEngineExtra(t, map[string]string{"protected.yaml": definition})
				defer journal.Close()
				e.ProtectedPaths = []string{state}
				var streamed strings.Builder
				request := Request{
					ActionID: "t.protected_path", Args: map[string]any{"path": operand}, Reason: "test protected path",
					OnProgress: func(_ executor.Stream, data []byte) { streamed.Write(data) },
				}
				result, err := e.Run(t.Context(), request)
				if err != nil || result.Status != StatusValidationFailed || !strings.Contains(result.Error, "runner's own configuration or state") {
					t.Fatalf("protected operand was not refused: result=%+v err=%v", result, err)
				}
				if streamed.Len() != 0 || result.Stdout != "" || result.ExecutedCommand != "" {
					t.Fatalf("refused action executed or emitted output: %+v stream=%q", result, streamed.String())
				}
				got, err := os.ReadFile(target)
				if err != nil || string(got) != content {
					t.Fatalf("protected file changed: %q (%v)", got, err)
				}
				events := readJournalEvents(t, root)
				if len(events) != 1 || events[0].Type != "validation_failed" {
					t.Fatalf("expected only a journaled refusal: %+v", events)
				}

				// Prove the fixture really reads/writes this relative operand
				// when the target is not protected; a broken command cannot pass.
				e.ProtectedPaths = nil
				request.OnProgress = nil
				result, err = e.Run(t.Context(), request)
				if err != nil || result.Status != StatusSuccess {
					t.Fatalf("unprotected control failed: result=%+v err=%v", result, err)
				}
				if operation == "read" && result.Stdout != content {
					t.Fatalf("control did not read fixture: %q", result.Stdout)
				}
				if operation == "truncate" {
					got, err = os.ReadFile(target)
					if err != nil || len(got) != 0 {
						t.Fatalf("control did not truncate fixture: %q (%v)", got, err)
					}
				}
			})
		}
	}
}
