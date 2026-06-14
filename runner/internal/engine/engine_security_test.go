package engine

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestEngine_ScalarArgIsLiteralArgvNoShell proves an LLM-supplied arg with
// shell metacharacters is passed to the process as ONE literal argv element
// through the full validate→render→exec path — never word-split, never
// shell-evaluated. This locks the argv-array execution model: if a future
// change ever introduced a shell-exec path, the injected `touch` commands
// below would run and fail this test.
func TestEngine_ScalarArgIsLiteralArgvNoShell(t *testing.T) {
	e, j, root := setupEngine(t)
	defer j.Close()

	marker := filepath.Join(root, "PWNED")
	payload := "hi; touch " + marker + " $(touch " + marker + ") `touch " + marker + "` && touch " + marker

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": payload},
		Reason:   "injection probe",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusSuccess {
		t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
	}
	// /bin/echo prints its single argv element verbatim + a newline.
	if got := strings.TrimRight(res.Stdout, "\n"); got != payload {
		t.Fatalf("arg was not passed as one literal argv element:\n got=%q\nwant=%q", got, payload)
	}
	// No shell ran, so none of the injected `touch` commands executed.
	if _, err := os.Stat(marker); err == nil {
		t.Fatalf("shell metacharacters were evaluated — %s was created", marker)
	}
}

// TestEngine_SuccessExitCodesAreExactAllowlist proves execution.success_exit_codes
// flips a DECLARED non-zero exit to success (iscsiadm's 21 = "no active sessions";
// journalctl --grep's 1 = "no matches") while an UNdeclared non-zero code still
// fails. This locks the executor's fail-visible posture: the allowlist is exact,
// never a blanket "non-zero is fine", so a real failure on an undeclared code is
// never masked.
func TestEngine_SuccessExitCodesAreExactAllowlist(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{
		"benign.yaml":     exitCodeAction("t.benign", 21, "[21]"),
		"undeclared.yaml": exitCodeAction("t.undeclared", 9, "[21]"),
	})
	defer j.Close()

	t.Run("declared benign code is success", func(t *testing.T) {
		res, err := e.Run(context.Background(), Request{ActionID: "t.benign", Reason: "test"})
		if err != nil {
			t.Fatal(err)
		}
		if res.Status != StatusSuccess {
			t.Fatalf("status=%s reason=%q, want success (21 is declared benign)", res.Status, res.Reason)
		}
		if res.ExitCode != 21 {
			t.Fatalf("exit=%d, want 21", res.ExitCode)
		}
		if res.Reason != "" {
			t.Fatalf("reason=%q, want empty (a success carries no failure reason)", res.Reason)
		}
	})

	t.Run("undeclared non-zero code still fails", func(t *testing.T) {
		res, err := e.Run(context.Background(), Request{ActionID: "t.undeclared", Reason: "test"})
		if err != nil {
			t.Fatal(err)
		}
		if res.Status != StatusFailed {
			t.Fatalf("status=%s, want failed (9 is NOT in the [21] allowlist)", res.Status)
		}
		if res.ExitCode != 9 {
			t.Fatalf("exit=%d, want 9", res.ExitCode)
		}
	})
}

// exitCodeAction builds a test action that exits with the given code and
// declares the given success_exit_codes (a YAML flow sequence, e.g. "[21]").
func exitCodeAction(id string, exitCode int, successExitCodes string) string {
	return fmt.Sprintf(`
schema_version: 1
id: %s
title: exits %d
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "exit %d"]
  timeout: 5s
  success_exit_codes: %s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`, id, exitCode, exitCode, successExitCodes)
}
