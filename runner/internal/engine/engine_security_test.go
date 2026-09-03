package engine

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/expressions"
	"github.com/andrewdryga/emisar/runner/internal/redact"
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
	// echo prints its single argv element verbatim + a newline.
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
	e.SetAdmission(pol)

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
    binary: true
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

	_, got := redactedInvocation(nil, "wg", argv, args, schema)
	for _, secret := range []string{"s3cr3t-alpha", "s3cr3t-beta"} {
		if strings.Contains(got, secret) {
			t.Fatalf("executed_command leaked list secret %q: %s", secret, got)
		}
	}
	if want := `wg --iface wg0 '[REDACTED]' '[REDACTED]'`; got != want {
		t.Fatalf("redactedInvocation() command = %q, want %q", got, want)
	}
}

func TestEngine_OverlappingSensitiveValuesRedactedLongestFirst(t *testing.T) {
	schema := []actionspec.Arg{
		{Name: "short", Sensitive: true},
		{Name: "long", Sensitive: true},
	}
	args := map[string]any{"short": "abc", "long": "abc123"}

	_, got := redactedInvocation(nil, "tool", []string{"--token=abc123"}, args, schema)
	if strings.Contains(got, "abc") || strings.Contains(got, "123") {
		t.Fatalf("executed_command leaked an overlapping secret: %s", got)
	}
	if want := `tool '--token=[REDACTED]'`; got != want {
		t.Fatalf("redactedInvocation() command = %q, want %q", got, want)
	}
}

func TestEngine_SensitiveValidationFailureReasonRedacted(t *testing.T) {
	const durationAction = `
schema_version: 1
id: t.sensitive_duration
title: Sensitive duration
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: api_token
    type: duration
    required: true
    sensitive: true
execution:
  command:
    binary: true
    argv: []
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
	const pathAction = `
schema_version: 1
id: t.sensitive_path
title: Sensitive path
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: secret_path
    type: path
    required: true
    sensitive: true
    validation:
      max_length: 1024
      denied_paths: [/token]
execution:
  command:
    binary: true
    argv: []
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

	e, journal, root := setupEngineExtra(t, map[string]string{
		"sensitive_duration.yaml": durationAction,
		"sensitive_path.yaml":     pathAction,
	})
	defer journal.Close()

	tests := []struct {
		actionID string
		arg      string
		secret   string
		leaks    []string
		want     string
	}{
		{
			actionID: "t.sensitive_duration",
			arg:      "api_token",
			secret:   "hunter2",
			leaks:    []string{"hunter2"},
			want:     "argument api_token: rejected sensitive value (type)",
		},
		{
			actionID: "t.sensitive_path",
			arg:      "secret_path",
			secret:   "/secret/../token",
			leaks:    []string{"/secret/../token", "/token"},
			want:     "argument secret_path: rejected sensitive value (denied_paths)",
		},
	}

	for _, test := range tests {
		t.Run(test.actionID, func(t *testing.T) {
			result, err := e.Run(context.Background(), Request{
				ActionID: test.actionID,
				Args:     map[string]any{test.arg: test.secret},
				Reason:   "test",
			})
			if err != nil {
				t.Fatal(err)
			}
			if result.Status != StatusValidationFailed {
				t.Fatalf("status=%s, want validation_failed", result.Status)
			}
			if result.Reason != test.want {
				t.Fatalf("reason=%q, want %q", result.Reason, test.want)
			}
			for _, leak := range test.leaks {
				if strings.Contains(result.Reason, leak) {
					t.Fatalf("validation reason leaked sensitive value %q: %q", leak, result.Reason)
				}
			}
		})
	}

	events, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	for _, leak := range []string{"hunter2", "/secret/../token", `"/token"`} {
		if strings.Contains(string(events), leak) {
			t.Fatalf("audit journal leaked sensitive validation value %q:\n%s", leak, events)
		}
	}
}

// A credential passed through an arg the pack author did not flag
// `sensitive: true` used to reach executed_command verbatim — into the local
// journal and the permanent cloud run record — while the identical bytes in
// the command's OUTPUT were masked by the default rule set. Both paths now run
// the same net.
func TestEngine_UnflaggedCredentialMaskedInExecutedCommand(t *testing.T) {
	defaults, err := redact.CompileAll(redact.DefaultRules())
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	engine := New(Config{Redactor: redact.New(defaults)})
	act := &actionspec.Action{
		ID:   "p.deploy",
		Args: []actionspec.Arg{{Name: "header", Type: actionspec.ArgString}},
	}
	args := map[string]any{"header": "Authorization: Bearer sk-live-abcdefghijklmnopqrst"}
	redactor := engine.combinedRedactor(act, args)

	argv := []string{"--header", args["header"].(string)}
	maskedArgv, command := redactedInvocation(redactor, "curl", argv, args, act.Args)

	if strings.Contains(command, "sk-live-abcdefghijklmnopqrst") {
		t.Fatalf("executed_command leaked an unflagged bearer token: %s", command)
	}
	if strings.Contains(strings.Join(maskedArgv, " "), "sk-live-abcdefghijklmnopqrst") {
		t.Fatalf("argv leaked an unflagged bearer token: %v", maskedArgv)
	}

	redactedArgs := redactArgs(redactor, args, act.Args)
	if header, _ := redactedArgs["header"].(string); strings.Contains(header, "sk-live-abcdefghijklmnopqrst") {
		t.Fatalf("args_redacted leaked an unflagged bearer token: %s", header)
	}
}

// validation.Validate hands a string_array arg to the engine as []string, and
// its elements land in argv exactly like a scalar's. Masking only the scalar
// wrote the same credential to events.jsonl masked in executed_command and in
// the clear in args_redacted — the journal operators export with
// `emisar audit`.
func TestEngine_UnflaggedCredentialInArrayArgMaskedInJournal(t *testing.T) {
	defaults, err := redact.CompileAll(redact.DefaultRules())
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	engine := New(Config{Redactor: redact.New(defaults)})
	act := &actionspec.Action{
		ID:   "databricks.job_run_now",
		Args: []actionspec.Arg{{Name: "job_params", Type: actionspec.ArgStringArray}},
	}
	const secret = "ghp_AAAAAAAAAAAAAAAAAAAAAAAA"
	args := map[string]any{"job_params": []string{"env=prod", "api_token=" + secret}}
	redactor := engine.combinedRedactor(act, args)

	redactedArgs := redactArgs(redactor, args, act.Args)
	params, ok := redactedArgs["job_params"].([]string)
	if !ok {
		t.Fatalf("job_params = %T, want []string", redactedArgs["job_params"])
	}
	if strings.Contains(strings.Join(params, " "), secret) {
		t.Fatalf("args_redacted leaked a credential in a string_array arg: %v", params)
	}
	if params[0] != "env=prod" {
		t.Fatalf("an ordinary element must survive unchanged, got %q", params[0])
	}
}

// A pack may legally name a redaction rule the same thing the synthesized
// sensitive-argument set is named. Compiled in one batch with it, CompileAll's
// first-wins dedupe silently dropped the pack's rule — and with it whatever else
// that rule masked, which then reached the journal and the portal in the clear.
func TestEngine_PackRuleNamedLikeASynthesizedOneStillApplies(t *testing.T) {
	act := &actionspec.Action{
		ID:   "test.collide",
		Args: []actionspec.Arg{{Name: "token", Sensitive: true}},
		Output: actionspec.Output{
			Redact: []actionspec.RedactionRule{{
				Name:        sensitiveArgsRule,
				Type:        "literal",
				Literal:     "unrelated-secret",
				Replacement: "[REDACTED]",
			}},
		},
	}

	e := &Engine{}
	redactor := e.combinedRedactor(act, map[string]any{"token": "arg-secret"})
	got, _ := redactor.Apply("saw arg-secret and unrelated-secret")

	for _, secret := range []string{"arg-secret", "unrelated-secret"} {
		if strings.Contains(got, secret) {
			t.Fatalf("redactor leaked %q: %s", secret, got)
		}
	}
}

// A sensitive value that is a substring of the redaction marker itself must not
// rewrite a marker an earlier secret already left behind. Masking per-secret in
// a loop produced "[R[REDACTED]ACTED]", which mangles the command an operator
// approves against and encodes which substring the value was.
func TestEngine_SecretInsideMarkerDoesNotCorruptRedaction(t *testing.T) {
	schema := []actionspec.Arg{
		{Name: "token", Sensitive: true},
		{Name: "mode", Sensitive: true},
	}
	args := map[string]any{"token": "s3cr3t-alpha", "mode": "ED"}

	_, got := redactedInvocation(nil, "tool", []string{"--token=s3cr3t-alpha", "--mode=ED"}, args, schema)
	if want := `tool '--token=[REDACTED]' '--mode=[REDACTED]'`; got != want {
		t.Fatalf("redactedInvocation() command = %q, want %q", got, want)
	}
}

// The same value through the combined redactor the real action path builds. Its
// synthesized rules run over the command a SECOND time and over the command's
// OUTPUT, so masking had to become one pass there too — per-value rules in
// sequence corrupted the marker in the journal and in what the portal shows.
func TestEngine_SecretInsideMarkerSurvivesCombinedRedactor(t *testing.T) {
	act := &actionspec.Action{
		ID: "p.deploy",
		Args: []actionspec.Arg{
			{Name: "token", Sensitive: true},
			{Name: "mode", Sensitive: true},
		},
	}
	args := map[string]any{"token": "s3cr3t-alpha", "mode": "ED"}
	engine := &Engine{}
	redactor := engine.combinedRedactor(act, args)

	_, command := redactedInvocation(redactor, "tool", []string{"--token=s3cr3t-alpha", "--mode=ED"}, args, act.Args)
	if want := `tool '--token=[REDACTED]' '--mode=[REDACTED]'`; command != want {
		t.Fatalf("redactedInvocation() command = %q, want %q", command, want)
	}

	// The output path is the one argv masking cannot cover: a child process that
	// echoes the value.
	output, _ := redactor.Apply("connecting with s3cr3t-alpha in ED mode")
	if want := "connecting with [REDACTED] in [REDACTED] mode"; output != want {
		t.Fatalf("redactor.Apply() = %q, want %q", output, want)
	}
}

// An authored rule that fails to compile must not take the sensitive-argument
// masking down with it — the arguments have nothing to do with the pack's
// mistake, and dropping them widens what reaches the journal and the portal.
func TestEngine_AuthoredRuleCompileFailureKeepsSensitiveMasking(t *testing.T) {
	act := &actionspec.Action{
		ID:   "test.badrule",
		Args: []actionspec.Arg{{Name: "token", Sensitive: true}},
		Output: actionspec.Output{
			Redact: []actionspec.RedactionRule{{
				Name:    "broken",
				Type:    "regex",
				Pattern: "([unclosed",
			}},
		},
	}

	engine := &Engine{Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	redactor := engine.combinedRedactor(act, map[string]any{"token": "arg-secret"})

	got, _ := redactor.Apply("saw arg-secret")
	if strings.Contains(got, "arg-secret") {
		t.Fatalf("a broken authored rule dropped sensitive-argument masking: %s", got)
	}
}

// A sensitive argument echoed near the action's byte cap must never ship its
// prefix. The executor used to cut the raw stream at exactly max_stdout_bytes,
// so a value straddling that offset reached redaction already split in half —
// the literal rule synthesized for it matched nothing and the leading bytes
// left the host in the clear. The cap now applies to redacted bytes.
func TestEngine_SecretStraddlingTheOutputCapIsMasked(t *testing.T) {
	const secret = "s3cr3t-value-that-must-never-ship-in-part"
	const yaml = `
schema_version: 1
id: t.cap_secret
title: Cap secret
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - {name: token, type: string, required: true, sensitive: true}
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "printf 'pad%s\n' \"$PAD\"; printf 'tok=%s\n' \"$TOKEN\"", "emisar", "{{ args.token }}"]
    # PAD fills the stream so the cap lands inside the token on the next line.
  env:
    PAD: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    TOKEN: "{{ args.token }}"
  timeout: 5s
output:
  max_stdout_bytes: 74
  max_stderr_bytes: 1024
`
	e, j, _ := setupEngineExtra(t, map[string]string{"cap_secret.yaml": yaml})
	defer j.Close()

	for _, streaming := range []bool{false, true} {
		name := "buffered"
		req := Request{ActionID: "t.cap_secret", Args: map[string]any{"token": secret}, Reason: "test"}
		if streaming {
			name = "streaming"
			req.OnProgress = func(executor.Stream, []byte) {}
		}
		t.Run(name, func(t *testing.T) {
			var streamed strings.Builder
			if streaming {
				req.OnProgress = func(_ executor.Stream, data []byte) { streamed.Write(data) }
			}
			res, err := e.Run(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if res.Status != StatusSuccess {
				t.Fatalf("status=%s reason=%s", res.Status, res.Reason)
			}
			if len(res.Stdout) > 74 {
				t.Fatalf("stdout is %d bytes, over the declared 74: %q", len(res.Stdout), res.Stdout)
			}
			// Any prefix of the secret long enough to be recognizable must be
			// absent — the leak was the first N bytes, not the whole value.
			if strings.Contains(res.Stdout, secret[:20]) {
				t.Fatalf("stdout leaked the start of a sensitive argument: %q", res.Stdout)
			}
			if streaming && strings.Contains(streamed.String(), secret[:20]) {
				t.Fatalf("a progress chunk leaked the start of a sensitive argument: %q", streamed.String())
			}
		})
	}
}
