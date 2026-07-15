package engine

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/expressions"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
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

// TestEngine_MaxRiskBlocksAboveCeiling proves the risk ceiling is enforced at
// dispatch, not just hidden from the catalog: a resolvable, trusted high-risk
// action is refused with StatusBlockedByAdmission + a journal entry when the
// runner's ceiling is below it, so a stale or compromised portal cannot run
// what a read-only demo suppressed. The low-risk action still passes.
func TestEngine_MaxRiskBlocksAboveCeiling(t *testing.T) {
	e, j, _ := setupEngineExtra(t, map[string]string{"reboot.yaml": rebootHighRiskAction})
	defer j.Close()

	pol, err := admission.New(nil, nil, actionspec.RiskMedium)
	if err != nil {
		t.Fatal(err)
	}
	e.Admission = pol

	low, err := e.Run(context.Background(), Request{
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "hi"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if low.Status == StatusBlockedByAdmission {
		t.Fatalf("low-risk action should pass a medium ceiling, got blocked: %s", low.Reason)
	}

	res, err := e.Run(context.Background(), Request{
		ActionID: "t.reboot",
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusBlockedByAdmission {
		t.Fatalf("expected blocked, got status=%s reason=%s", res.Status, res.Reason)
	}
	if !strings.Contains(res.Reason, "ceiling") {
		t.Fatalf("expected a risk-ceiling reason, got %q", res.Reason)
	}
	if res.EventID == "" {
		t.Fatal("expected an event id on the blocked result")
	}
}

const rebootHighRiskAction = `
schema_version: 1
id: t.reboot
title: Reboot
kind: exec
risk: high
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/true
    argv: []
  timeout: 5s
  timeout_min: 1s
  timeout_max: 30s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

// TestEngine_SensitiveListRedactedPerElement proves a list-typed sensitive arg
// is masked element-by-element in executed_command. RenderArgv expands the list
// into separate argv tokens; sensitiveValues used to stringify it only as the
// bracketed "[a b]" whole form, which matches no individual token — so the raw
// elements leaked into the one command string that leaves the host. Redaction
// is a security boundary, so this lives in the security suite.
func TestEngine_SensitiveListRedactedPerElement(t *testing.T) {
	schema := []actionspec.Arg{
		{Name: "iface"},
		{Name: "keys", Sensitive: true, Type: actionspec.ArgStringArray},
	}
	args := map[string]any{
		"iface": "wg0",
		"keys":  []string{"s3cr3t-alpha", "s3cr3t-beta"},
	}

	// Build argv through the real render path so the tokens are exactly what
	// would reach exec: the sensitive list expands into two separate elements.
	argv, err := expressions.RenderArgv([]string{"--iface", "{{ args.iface }}", "{{ args.keys }}"}, args)
	if err != nil {
		t.Fatalf("RenderArgv: %v", err)
	}

	got := redactedCommand("wg", argv, args, schema)
	for _, secret := range []string{"s3cr3t-alpha", "s3cr3t-beta"} {
		if strings.Contains(got, secret) {
			t.Fatalf("executed_command leaked list secret %q: %s", secret, got)
		}
	}
	if want := `wg --iface wg0 '[REDACTED]' '[REDACTED]'`; got != want {
		t.Fatalf("redactedCommand() = %q, want %q", got, want)
	}
}

func TestEngine_OverlappingSensitiveValuesRedactedLongestFirst(t *testing.T) {
	schema := []actionspec.Arg{
		{Name: "short", Sensitive: true},
		{Name: "long", Sensitive: true},
	}
	args := map[string]any{"short": "abc", "long": "abc123"}

	got := redactedCommand("tool", []string{"--token=abc123"}, args, schema)
	if strings.Contains(got, "abc") || strings.Contains(got, "123") {
		t.Fatalf("executed_command leaked an overlapping secret: %s", got)
	}
	if want := `tool '--token=[REDACTED]'`; got != want {
		t.Fatalf("redactedCommand() = %q, want %q", got, want)
	}
}
