package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/engine"
)

// probePack describes one pack to stage for a verify test: what its declared
// verify action runs, and whether that action demands an argument the probe
// has no value for.
type probePack struct {
	id      string
	binary  string
	argv    []string
	reqArg  string
	noVerif bool
}

// writeProbePacks stages each pack under a fresh packs dir and returns it.
// Each pack's single action is what its setup.verify names, so the probe path
// is exercised end to end rather than against a stub.
func writeProbePacks(t *testing.T, root string, packs ...probePack) string {
	t.Helper()
	for _, p := range packs {
		dir := filepath.Join(root, p.id)
		if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
			t.Fatalf("mkdir pack %s: %v", p.id, err)
		}
		manifest := "schema_version: 1\nid: " + p.id + "\nname: " + p.id + "\nversion: 0.0.1\ndescription: d\n"
		if !p.noVerif {
			manifest += "setup:\n  verify: " + p.id + ".probe\n"
		}
		manifest += "actions:\n  - actions/probe.yaml\n"

		args := "args: []\n"
		if p.reqArg != "" {
			args = "args:\n  - name: " + p.reqArg + "\n    type: string\n    required: true\n" +
				"    description: d\n    validation:\n      max_length: 64\n"
		}
		argv := make([]string, 0, len(p.argv))
		for _, a := range p.argv {
			argv = append(argv, fmt.Sprintf("%q", a))
		}
		action := "schema_version: 1\nid: " + p.id + ".probe\ntitle: Probe\nkind: exec\nrisk: low\n" +
			"description: d\nside_effects: [none]\n" + args +
			"execution:\n  command:\n    binary: " + p.binary + "\n    argv: [" + strings.Join(argv, ", ") + "]\n" +
			"  timeout: 10s\n  timeout_min: 1s\n  timeout_max: 30s\n" +
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"

		if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
			t.Fatalf("write pack.yaml %s: %v", p.id, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "actions", "probe.yaml"), []byte(action), 0o644); err != nil {
			t.Fatalf("write action %s: %v", p.id, err)
		}
	}
	return root
}

// runPackVerify drives the real command and returns its stdout plus the error
// its exit status carries.
func runPackVerify(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var execErr error
	out := captureStdout(t, func() {
		cmd := packVerifyCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		execErr = cmd.Execute()
	})
	return out, execErr
}

// stageProbePacks wires a temp config + packs dir for a verify run and returns
// the temp root so a test can inspect the journal.
func stageProbePacks(t *testing.T, packs ...probePack) string {
	t.Helper()
	withFlags(t)
	withJSONOut(t, false)
	dir := t.TempDir()
	packDir := writeProbePacks(t, filepath.Join(dir, "packs"), packs...)
	flagConfig = writeMinimalConfig(t, dir, packDir)
	return dir
}

// A healthy pack probes green and the run exits 0. The action really executes,
// so this also pins that the probe goes through the engine rather than
// inspecting the manifest.
func TestPackVerify_HealthyPackIsOK(t *testing.T) {
	stageProbePacks(t, probePack{id: "good", binary: "true"})

	out, err := runPackVerify(t)
	if err != nil {
		t.Fatalf("pack verify must exit 0 when every probe passes: %v\n%s", err, out)
	}
	if !strings.Contains(out, "ok") || !strings.Contains(out, "good.probe") {
		t.Fatalf("want an ok row naming the verify action:\n%s", out)
	}
	if !strings.Contains(out, "1 ok") {
		t.Fatalf("want a count line:\n%s", out)
	}
}

// A failing probe carries the TARGET's own message, not just an exit code —
// that message ("permission denied", "invalid API key") is the whole reason to
// run the check. The run exits non-zero so an installer or CI step can branch.
func TestPackVerify_FailureCarriesTheTargetMessageAndExitsNonZero(t *testing.T) {
	stageProbePacks(t, probePack{
		id: "bad", binary: "/bin/sh", argv: []string{"-c", "echo 'auth failed: bad token' >&2; exit 3"},
	})

	out, err := runPackVerify(t)
	if err == nil {
		t.Fatalf("a failed probe must exit non-zero:\n%s", out)
	}
	if !strings.Contains(out, "auth failed: bad token") {
		t.Fatalf("failure row must carry the target's stderr:\n%s", out)
	}
	if !strings.Contains(out, "exit 3") {
		t.Fatalf("failure row must carry the exit code:\n%s", out)
	}
}

// A verify action needing an argument the host cannot infer (a project id, a
// hostname) is SKIPPED, and a skip is NOT a failure — 22 of the shipped packs
// are in this shape, so failing on them would make the check permanently red
// on a normal fleet. The row names the command that completes the probe.
func TestPackVerify_MissingRequiredArgSkipsWithoutFailing(t *testing.T) {
	stageProbePacks(t, probePack{id: "needsarg", binary: "true", reqArg: "project"})

	out, err := runPackVerify(t)
	if err != nil {
		t.Fatalf("a skip must not fail the run: %v\n%s", err, out)
	}
	if !strings.Contains(out, "skipped") {
		t.Fatalf("want a skipped row:\n%s", out)
	}
	if !strings.Contains(out, "emisar pack verify needsarg --arg project=<value>") {
		t.Fatalf("skip row must name the completable command:\n%s", out)
	}
}

// --arg supplies what the host can't infer, so an operator can probe the packs
// the fleet-wide run has to skip.
func TestPackVerify_ArgFlagCompletesASkippedProbe(t *testing.T) {
	stageProbePacks(t, probePack{id: "needsarg", binary: "true", reqArg: "project"})

	out, err := runPackVerify(t, "needsarg", "--arg", "project=acme-prod")
	if err != nil {
		t.Fatalf("pack verify with --arg: %v\n%s", err, out)
	}
	if strings.Contains(out, "skipped") {
		t.Fatalf("the supplied arg must un-skip the probe:\n%s", out)
	}
	if !strings.Contains(out, "ok") {
		t.Fatalf("want an ok row:\n%s", out)
	}
}

// --arg names one action's parameters. Spread across a set it would feed the
// same value to unrelated schemas and fail them all as unknown_arg, so the
// command refuses instead of running.
func TestPackVerify_ArgFlagRequiresExactlyOnePack(t *testing.T) {
	stageProbePacks(t,
		probePack{id: "one", binary: "true", reqArg: "project"},
		probePack{id: "two", binary: "true"},
	)

	if _, err := runPackVerify(t, "--arg", "project=x"); err == nil {
		t.Fatal("--arg with no pack id must error")
	}
	if _, err := runPackVerify(t, "one", "two", "--arg", "project=x"); err == nil {
		t.Fatal("--arg across two packs must error")
	}
}

// The break-glass shell pack declares no verify action — nothing about an
// arbitrary operator-supplied command is probeable. It reports as a skip, not
// as a broken pack.
func TestPackVerify_PackWithoutVerifyIsSkipped(t *testing.T) {
	stageProbePacks(t, probePack{id: "breakglass", binary: "true", noVerif: true})

	out, err := runPackVerify(t)
	if err != nil {
		t.Fatalf("a pack with no verify must not fail the run: %v\n%s", err, out)
	}
	if !strings.Contains(out, "declares no verify action") {
		t.Fatalf("want the no-verify skip reason:\n%s", out)
	}
}

// A named pack that isn't installed is an error, not a silently empty run —
// a typo must not read as "everything is fine".
func TestPackVerify_UnknownPackIsAnError(t *testing.T) {
	stageProbePacks(t, probePack{id: "good", binary: "true"})

	if _, err := runPackVerify(t, "nope"); err == nil {
		t.Fatal("naming an uninstalled pack must error")
	}
}

// The probe executes a real action, so it must land in the local audit journal
// exactly like an operator-initiated `action run`. There is no unlogged
// execution path in this binary.
func TestPackVerify_ProbeIsJournaled(t *testing.T) {
	dir := stageProbePacks(t, probePack{id: "good", binary: "true"})

	if _, err := runPackVerify(t); err != nil {
		t.Fatalf("pack verify: %v", err)
	}
	events, err := os.ReadFile(filepath.Join(dir, "events.jsonl"))
	if err != nil {
		t.Fatalf("the probe must write the audit journal: %v", err)
	}
	if !strings.Contains(string(events), "good.probe") {
		t.Fatalf("journal must record the executed verify action:\n%s", events)
	}
	if !strings.Contains(string(events), verifyReason) {
		t.Fatalf("journal must record why it ran (%q):\n%s", verifyReason, events)
	}
}

// --json is what a fleet script parses, so the documented snake_case shape is
// pinned: counts at the top, one row per pack, no Go field names.
func TestPackVerify_JSONShape(t *testing.T) {
	stageProbePacks(t,
		probePack{id: "good", binary: "true"},
		probePack{id: "needsarg", binary: "true", reqArg: "project"},
	)
	withJSONOut(t, true)

	out, err := runPackVerify(t)
	if err != nil {
		t.Fatalf("pack verify --json: %v\n%s", err, out)
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("--json output is not an object: %v\n%s", err, out)
	}
	for _, key := range []string{"status", "ok", "failed", "skipped", "packs"} {
		if _, ok := report[key]; !ok {
			t.Errorf("report missing %q: %v", key, keysOf(report))
		}
	}
	for _, forbidden := range []string{"Status", "OK", "Failed", "Skipped", "Packs"} {
		if _, ok := report[forbidden]; ok {
			t.Errorf("report must not carry %q: %v", forbidden, keysOf(report))
		}
	}
	rows, ok := report["packs"].([]any)
	if !ok || len(rows) != 2 {
		t.Fatalf("want two pack rows, got %#v", report["packs"])
	}
	row, ok := rows[0].(map[string]any)
	if !ok {
		t.Fatalf("row is not an object: %#v", rows[0])
	}
	for _, key := range []string{"pack_id", "action_id", "status"} {
		if _, ok := row[key]; !ok {
			t.Errorf("row missing %q: %v", key, keysOf(row))
		}
	}
	if report["status"] != verifyOK {
		t.Errorf("a run with only ok and skipped rows is %q, want %q", report["status"], verifyOK)
	}
}

// classifyVerify decides what counts as a broken pack. The two judgment calls
// are pinned here: an admission block is the operator's own deny rule doing
// its job (skip), and everything else that isn't success is a failure.
func TestClassifyVerify(t *testing.T) {
	tests := []struct {
		name       string
		result     engine.Result
		wantStatus string
		wantDetail string
	}{
		{
			name:       "success",
			result:     engine.Result{Status: engine.StatusSuccess},
			wantStatus: verifyOK,
		},
		{
			name:       "admission block is the host's own decision, not a broken pack",
			result:     engine.Result{Status: engine.StatusBlockedByAdmission, Reason: "denied by policy"},
			wantStatus: verifySkipped,
			wantDetail: "blocked by this runner's admission policy",
		},
		{
			name:       "timeout names the elapsed time",
			result:     engine.Result{Status: engine.StatusTimedOut, DurationMS: 9000},
			wantStatus: verifyFailed,
			wantDetail: "timed out after 9000ms",
		},
		{
			name: "stderr leads: it carries the target's own message",
			result: engine.Result{
				Status: engine.StatusFailed, ExitCode: 2,
				Stderr: "psql: error: connection failed", Reason: "process exited with code 2",
			},
			wantStatus: verifyFailed,
			wantDetail: "failed (exit 2): psql: error: connection failed",
		},
		{
			name: "reason wins when the process never produced output",
			result: engine.Result{
				Status: engine.StatusError, ExitCode: -1,
				Reason: `exec: "dpkg": executable file not found in $PATH`,
			},
			wantStatus: verifyFailed,
			wantDetail: `error: exec: "dpkg": executable file not found in $PATH`,
		},
		{
			name: "validation failure explains which argument was wrong",
			result: engine.Result{
				Status: engine.StatusValidationFailed, Reason: "argument project: is required",
			},
			wantStatus: verifyFailed,
			wantDetail: "validation_failed: argument project: is required",
		},
		{
			name:       "a silent failure still names the status",
			result:     engine.Result{Status: engine.StatusFailed, ExitCode: 1},
			wantStatus: verifyFailed,
			wantDetail: "failed (exit 1)",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			status, detail := classifyVerify(&test.result)
			if status != test.wantStatus {
				t.Errorf("status = %q, want %q", status, test.wantStatus)
			}
			if detail != test.wantDetail {
				t.Errorf("detail = %q, want %q", detail, test.wantDetail)
			}
		})
	}
}

// A negative exit code means the process never started, so printing it would
// read as a real exit status the operator could look up.
func TestVerifyFailureDetail_HidesANonExitCode(t *testing.T) {
	detail := verifyFailureDetail(&engine.Result{Status: engine.StatusError, ExitCode: -1, Reason: "boom"})
	if strings.Contains(detail, "-1") {
		t.Errorf("detail must not present -1 as an exit status: %q", detail)
	}
}

// The detail is bounded so one chatty target can't turn the table into a wall
// of text — and it is bounded by RUNES, so a multi-byte message is never cut
// into invalid UTF-8.
func TestTruncateDetail_BoundsWithoutSplittingARune(t *testing.T) {
	short := "already short"
	if got := truncateDetail(short); got != short {
		t.Errorf("short detail must pass through: %q", got)
	}
	long := strings.Repeat("é", verifyDetailMax*2)
	got := truncateDetail(long)
	if !strings.HasSuffix(got, "…") {
		t.Errorf("a truncated detail must be marked: %q", got)
	}
	if strings.ContainsRune(got, '�') {
		t.Errorf("truncation split a multi-byte rune: %q", got)
	}
	if len([]rune(got)) > verifyDetailMax+1 {
		t.Errorf("detail = %d runes, want <= %d", len([]rune(got)), verifyDetailMax+1)
	}
}

// missingRequiredArgs must test Required alone: validation.Validate rejects a
// missing required arg BEFORE it ever looks at Default, so a declared default
// does not make the probe runnable.
func TestMissingRequiredArgs_ADefaultDoesNotSatisfyRequired(t *testing.T) {
	stageProbePacks(t, probePack{id: "p", binary: "true", reqArg: "project"})
	rt, err := boot()
	if err != nil {
		t.Fatalf("boot: %v", err)
	}
	defer rt.journal.Close()

	action, ok := rt.registry().Action("p.probe")
	if !ok {
		t.Fatal("probe action not loaded")
	}
	action.Args[0].Default = "fallback"
	if missing := missingRequiredArgs(action, nil); len(missing) != 1 || missing[0] != "project" {
		t.Fatalf("missingRequiredArgs = %v, want [project] despite the default", missing)
	}
	if missing := missingRequiredArgs(action, map[string]any{"project": "x"}); len(missing) != 0 {
		t.Fatalf("a supplied value must satisfy the arg, got %v", missing)
	}
}

// doctor's contract is that it executes NOTHING by default — every check reads
// local state or opens one HTTP request. The probe is opt-in, and the audit
// journal is the proof: a plain run never creates it.
func TestDoctor_ProbeIsOptIn(t *testing.T) {
	dir := stageProbePacks(t, probePack{id: "good", binary: "true"})

	offline := runDoctor(context.Background(), false)
	if named(offline, "pack verify") != nil {
		t.Fatal("plain doctor must not include the pack verify check")
	}
	if _, err := os.Stat(filepath.Join(dir, "events.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("plain doctor executed an action (journal exists): %v", err)
	}

	probed := runDoctor(context.Background(), true)
	check := named(probed, "pack verify")
	if check == nil {
		t.Fatal("doctor --probe must include the pack verify check")
	}
	if check.status != checkOK {
		t.Fatalf("healthy pack should pass: %v — %s", check.status, check.detail)
	}
	if _, err := os.Stat(filepath.Join(dir, "events.jsonl")); err != nil {
		t.Fatalf("the probe must be journaled: %v", err)
	}
}

// A failed probe fails doctor, and the line names the pack, its action, and
// the reason — enough to act on without a second command.
func TestDoctor_ProbeReportsFailingPacks(t *testing.T) {
	stageProbePacks(t,
		probePack{id: "good", binary: "true"},
		probePack{id: "bad", binary: "/bin/sh", argv: []string{"-c", "echo nope >&2; exit 1"}},
	)

	check := named(runDoctor(context.Background(), true), "pack verify")
	if check == nil {
		t.Fatal("doctor --probe must include the pack verify check")
	}
	if check.status != checkFail {
		t.Fatalf("status = %v, want fail: %s", check.status, check.detail)
	}
	for _, want := range []string{"bad", "bad.probe", "nope", "1 of 2 packs verified"} {
		if !strings.Contains(check.detail, want) {
			t.Errorf("detail missing %q: %s", want, check.detail)
		}
	}
}

func named(results []checkResult, name string) *checkResult {
	for i := range results {
		if results[i].name == name {
			return &results[i]
		}
	}
	return nil
}
