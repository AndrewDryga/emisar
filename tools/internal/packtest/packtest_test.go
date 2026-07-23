package packtest

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestRunExecutesBehaviorProbeAndCleanup(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	root := t.TempDir()
	packDir := filepath.Join(root, "packs", "example")
	write(t, filepath.Join(packDir, "actions", "inspect.yaml"), "id: example.inspect\nrisk: low\n")
	write(t, filepath.Join(packDir, "actions", "mutate.yaml"), "id: example.mutate\nrisk: high\n")
	write(t, filepath.Join(packDir, "test", "cases.yaml"), `services: [fixture]
versions:
  - version: "1.0"
    digest: "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    default: true
env:
  FIXTURE: present
defaults:
  expect:
    stdout_not_empty: true
cases:
  - action: example.inspect
    args: {count: 3, name: demo}
    expect:
      stdout_contains: [present, "count=3", 'name="demo"']
  - action: example.mutate
    probes:
      - argv: ["`+filepath.Join(root, "probe")+`"]
        expect:
          stdout_contains: [changed]
    cleanup:
      - argv: ["`+filepath.Join(root, "cleanup")+`"]
`)
	emisar := filepath.Join(root, "emisar")
	writeExecutable(t, emisar, "#!/bin/sh\nprintf '{\"status\":\"success\",\"exit_code\":0,\"stdout\":\"present count=3 name=\\\\\"demo\\\\\"\"}\\n'\nprintf changed > \""+filepath.Join(root, "state")+"\"\n")
	writeExecutable(t, filepath.Join(root, "probe"), "#!/bin/sh\ncat \""+filepath.Join(root, "state")+"\"\n")
	writeExecutable(t, filepath.Join(root, "cleanup"), "#!/bin/sh\nprintf cleaned > \""+filepath.Join(root, "state")+"\"\n")

	var output bytes.Buffer
	totals, err := Run(Config{
		Emisar: emisar, PacksDir: filepath.Join(root, "packs"), Config: "test.yaml",
		Reports: filepath.Join(root, "reports"), Out: &output,
	})
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, output.String())
	}
	if totals.Pass != 2 || totals.Fail != 0 || totals.Actions != 2 || totals.Behavior != 2 || totals.Contract != 0 {
		t.Fatalf("totals = %+v", totals)
	}
	state, err := os.ReadFile(filepath.Join(root, "state"))
	if err != nil {
		t.Fatal(err)
	}
	if string(state) != "cleaned" {
		t.Fatalf("cleanup state = %q", state)
	}
}

func TestRunCaseRetainsActionResultWhenProbeFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	root := t.TempDir()
	emisar := filepath.Join(root, "emisar")
	writeExecutable(t, emisar, "#!/bin/sh\nprintf '{\"status\":\"success\",\"exit_code\":0,\"stdout\":\"ready\",\"duration_ms\":7}\\n'\n")

	err := runCase(
		Config{Emisar: emisar, Config: "test.yaml"},
		Plan{},
		Case{
			Action: "example.inspect",
			Expect: Expectation{StdoutContains: []string{"ready"}},
			Probes: []Step{{
				Argv:   []string{"/bin/sh", "-c", "exit 1"},
				Expect: Expectation{StdoutContains: []string{"never"}},
			}},
		},
		actionDefinition{ID: "example.inspect", Risk: "low"},
		os.Environ(),
	)
	if err == nil || !strings.Contains(err.Error(), `"duration_ms": 7`) {
		t.Fatalf("failed probe did not retain action result: %v", err)
	}
}

func TestArgumentValuePreservesNumericStrings(t *testing.T) {
	got, err := argumentValue("1")
	if err != nil {
		t.Fatal(err)
	}
	if got != `"1"` {
		t.Fatalf("argumentValue numeric string = %q, want JSON string", got)
	}
}

func TestResolveArgumentCapturesAndTypesOneLine(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	integer, err := resolveArgument(Step{
		Argv: []string{"/bin/sh", "-c", "printf 42"},
	}, os.Environ(), "integer")
	if err != nil {
		t.Fatal(err)
	}
	if integer != int64(42) {
		t.Fatalf("resolved integer = %#v", integer)
	}
	text, err := resolveArgument(Step{
		Argv: []string{"/bin/sh", "-c", "printf fixture-id"},
	}, os.Environ(), "string")
	if err != nil {
		t.Fatal(err)
	}
	if text != "fixture-id" {
		t.Fatalf("resolved string = %#v", text)
	}
	if _, err := resolveArgument(Step{
		Argv: []string{"/bin/sh", "-c", "printf 'one\\ntwo\\n'"},
	}, os.Environ(), "string"); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("multi-line argument error = %v", err)
	}
}

func TestActionAssertionsCoverFailureNegativesAndJSONPointers(t *testing.T) {
	failed := actionResult{
		Status: "failed", ExitCode: 42, Reason: "target unavailable",
		Stdout: "safe output", Stderr: "connection refused",
	}
	err := checkActionResult(failed, Expectation{
		Status: "failure", Exit: []int{42},
		ReasonContains:    []string{"unavailable"},
		StdoutNotContains: []string{"packtest-canary"},
		StderrContains:    []string{"refused"},
		StderrNotContains: []string{"password"},
	}, false)
	if err != nil {
		t.Fatal(err)
	}

	stdout := `{"status":"healthy","items":[{"name":"fixture"}],"a/b":{"~key":true}}`
	if err := checkJSONAssertions(stdout, map[string]any{
		"/status":       "healthy",
		"/items/0/name": "fixture",
		"/a~1b/~0key":   true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := checkActionResult(actionResult{
		Status: "success", Stdout: "not-json",
	}, Expectation{Status: "success", Exit: []int{0}, StdoutContains: []string{"not"}}, true); err == nil ||
		!strings.Contains(err.Error(), "not valid JSON") {
		t.Fatalf("JSON action accepted invalid output: %v", err)
	}
	if err := checkActionResult(actionResult{
		Status: "failed", ExitCode: 22,
	}, Expectation{Status: "failure", Exit: []int{22}}, true); err != nil {
		t.Fatalf("JSON action required a success document for an expected failure: %v", err)
	}
}

func TestFailureExpectationDoesNotInheritSuccessSmokeDefault(t *testing.T) {
	defaults := Expectation{StdoutNotEmpty: true}
	failure := mergeActionExpectation(defaults, Expectation{Status: "failure", Exit: []int{22}})
	if failure.StdoutNotEmpty {
		t.Fatal("expected failure inherited the success-only stdout smoke assertion")
	}
	success := mergeActionExpectation(defaults, Expectation{})
	if !success.StdoutNotEmpty {
		t.Fatal("expected success did not inherit the stdout smoke assertion")
	}
}

func TestSecretCanariesAreAbsentFromResultAndEventLog(t *testing.T) {
	eventLog := filepath.Join(t.TempDir(), "events.jsonl")
	write(t, eventLog, `{"action_id":"example.inspect"}`+"\n")
	env := map[string]string{"PASSWORD": "packtest-canary-password-9c0fb3"}
	result := actionResult{Status: "success", Stdout: "safe"}
	if err := checkSecretCanaries([]string{"PASSWORD"}, env, result, eventLog); err != nil {
		t.Fatal(err)
	}
	result.Reason = env["PASSWORD"]
	if err := checkSecretCanaries([]string{"PASSWORD"}, env, result, eventLog); err == nil ||
		!strings.Contains(err.Error(), "reason") {
		t.Fatalf("leaked canary passed: %v", err)
	}
}

func TestSecretCanariesCanBeEmbeddedAndEnvironmentCanBeUnset(t *testing.T) {
	env := map[string]string{
		"URL": "https://user:packtest-canary-password-72af@example.test",
	}
	if err := validateSecretEnv([]string{"URL"}, env); err != nil {
		t.Fatal(err)
	}
	got := withoutEnvironment([]string{"A=one", "PASSWORD=secret", "B=two"}, []string{"PASSWORD"})
	if strings.Join(got, ",") != "A=one,B=two" {
		t.Fatalf("withoutEnvironment = %v", got)
	}
}

func TestSecretCanariesUseEffectiveCaseEnvironment(t *testing.T) {
	eventLog := filepath.Join(t.TempDir(), "events.jsonl")
	write(t, eventLog, `{"action_id":"example.inspect"}`+"\n")
	base := []string{
		"PASSWORD=packtest-canary-password-plan",
		"REMOVED=packtest-canary-removed-plan",
	}
	effective := environment(base, map[string]string{
		"PASSWORD": "packtest-canary-password-case",
	})
	effective = withoutEnvironment(effective, []string{"REMOVED"})
	values := environmentMap(effective)

	if values["PASSWORD"] != "packtest-canary-password-case" {
		t.Fatalf("effective PASSWORD = %q", values["PASSWORD"])
	}
	if _, exists := values["REMOVED"]; exists {
		t.Fatalf("unset secret remains in effective environment: %#v", values)
	}
	result := actionResult{
		Status: "failure",
		Reason: values["PASSWORD"],
	}
	if err := checkSecretCanaries([]string{"PASSWORD", "REMOVED"}, values, result, eventLog); err == nil ||
		!strings.Contains(err.Error(), "PASSWORD") {
		t.Fatalf("case-level secret leak passed: %v", err)
	}
}

func TestRunStepRetriesAtTheConfiguredDeadline(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	root := t.TempDir()
	marker := filepath.Join(root, "attempted")
	probe := filepath.Join(root, "probe")
	writeExecutable(t, probe, "#!/bin/sh\nif [ ! -e \""+marker+"\" ]; then touch \""+marker+"\"; exit 1; fi\nprintf ready\n")

	err := runStep(Step{
		Argv:       []string{probe},
		Expect:     Expectation{StdoutContains: []string{"ready"}},
		RetryFor:   "500ms",
		RetryEvery: "500ms",
	}, os.Environ(), true)
	if err != nil {
		t.Fatalf("runStep did not retry at deadline: %v", err)
	}
}

func TestExecuteTimesOutHungCommands(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	previous := commandTimeout
	commandTimeout = 10 * time.Millisecond
	t.Cleanup(func() { commandTimeout = previous })

	_, err := execute([]string{"/bin/sh", "-c", "sleep 1"}, os.Environ())
	if err == nil || !strings.Contains(err.Error(), "command timed out after 10ms") {
		t.Fatalf("execute error = %v", err)
	}
}

func TestPlanValidationRejectsFalseCoverage(t *testing.T) {
	actions := map[string]actionDefinition{
		"example.read": {
			ID: "example.read", Risk: "low",
			Args: []actionArgument{{Name: "target", Type: "string"}},
		},
		"example.sensitive_read": {ID: "example.sensitive_read", Risk: "medium", SideEffects: []string{"Read-only, but exposes secrets."}},
		"example.mutate":         {ID: "example.mutate", Risk: "high"},
	}
	tests := []struct {
		name string
		plan Plan
		want string
	}{
		{"no services", Plan{Versions: testVersions(), Cases: []Case{{Action: "example.read", Expect: Expectation{StdoutNotEmpty: true}}}}, "services"},
		{"exit only", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{{Action: "example.read"}}}, "no semantic assertion"},
		{"unknown action", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{{Action: "missing", Expect: Expectation{StdoutNotEmpty: true}}}}, "does not exist"},
		{"duplicate", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{
			{Action: "example.read", Expect: Expectation{StdoutContains: []string{"ok"}}},
			{Action: "example.read", Expect: Expectation{StdoutContains: []string{"ok"}}},
		}}, "duplicates"},
		{"mutation without probe", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{
			{Action: "example.mutate", Expect: Expectation{StdoutContains: []string{"changed"}}, Cleanup: []Step{{Argv: []string{"true"}}}},
		}}, "state probe"},
		{"root without reason", Plan{Services: []string{"fixture"}, Versions: testVersions(), Runner: Runner{User: "root"}, Cases: []Case{
			{Action: "example.read", Expect: Expectation{StdoutContains: []string{"ok"}}},
		}}, "requires a reason"},
		{"case root without reason", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{
			{Action: "example.read", RunnerUser: "root", Expect: Expectation{StdoutContains: []string{"ok"}}},
		}}, "requires runner_reason"},
		{"case secret override without canary", Plan{
			Services:  []string{"fixture"},
			Versions:  testVersions(),
			SecretEnv: []string{"PASSWORD"},
			Env:       map[string]string{"PASSWORD": "packtest-canary-password-plan"},
			Cases: []Case{{
				Action: "example.read",
				Env:    map[string]string{"PASSWORD": "plain-secret"},
				Expect: Expectation{StdoutContains: []string{"ok"}},
			}},
		}, "must contain a packtest-canary- value"},
		{"unknown resolved argument", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{{
			Action:      "example.read",
			Expect:      Expectation{StdoutContains: []string{"ok"}},
			ResolveArgs: map[string]Step{"missing": {Argv: []string{"echo", "value"}}},
		}}}, "does not name an action argument"},
		{"duplicate resolved argument", Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{{
			Action: "example.read",
			Args:   map[string]any{"target": "static"},
			Expect: Expectation{StdoutContains: []string{"ok"}},
			ResolveArgs: map[string]Step{
				"target": {Argv: []string{"echo", "dynamic"}},
			},
		}}}, "duplicates a static argument"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validatePlan("example", test.plan, actions)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validatePlan error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestPlanValidationAcceptsSensitiveReadAndJustifiedMutation(t *testing.T) {
	actions := map[string]actionDefinition{
		"example.read": {
			ID: "example.read", Risk: "medium",
			SideEffects: []string{"Read-only, but may expose secrets."},
		},
		"example.reload": {ID: "example.reload", Risk: "high"},
	}
	plan := Plan{Services: []string{"fixture"}, Versions: testVersions(), Cases: []Case{
		{Action: "example.read", Expect: Expectation{StdoutContains: []string{"safe"}}},
		{
			Action: "example.reload", Expect: Expectation{StdoutContains: []string{"reloaded"}},
			Probes: []Step{{Argv: []string{"echo", "ready"}, Expect: Expectation{StdoutContains: []string{"ready"}}}},
		},
	}}
	if err := validatePlan("example", plan, actions); err != nil {
		t.Fatalf("validatePlan error = %v", err)
	}
}

func TestCompleteRiskAccountabilityRequiresSuccessOrKnownException(t *testing.T) {
	actions := map[string]actionDefinition{
		"example.restart": {ID: "example.restart", Risk: "high"},
		"example.remove":  {ID: "example.remove", Risk: "critical"},
	}
	plan := Plan{
		Services: []string{"fixture"}, Versions: testVersions(),
		RiskAccountability: RiskAccountability{Mode: "complete"},
		Cases: []Case{{
			Action: "example.restart",
			Expect: Expectation{Status: "failure", ReasonContains: []string{"denied"}},
		}},
	}
	if err := validatePlan("example", plan, actions); err == nil ||
		!strings.Contains(err.Error(), "example.restart") {
		t.Fatalf("failure-only risk case counted as coverage: %v", err)
	}
	plan.Cases[0].Expect = Expectation{StdoutContains: []string{"restarted"}}
	plan.Cases[0].Probes = []Step{{
		Argv: []string{"echo", "ready"}, Expect: Expectation{StdoutContains: []string{"ready"}},
	}}
	plan.RiskAccountability.Exceptions = map[string]string{
		"example.remove": "requires_cluster",
	}
	if err := validatePlan("example", plan, actions); err != nil {
		t.Fatalf("complete risk accountability rejected: %v", err)
	}
}

func TestStdoutNotEmptyIsSmokeNotSemanticCoverage(t *testing.T) {
	if (Expectation{StdoutNotEmpty: true}).semantic() {
		t.Fatal("stdout_not_empty counted as semantic coverage")
	}
}

func TestLoadPlanRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cases.yaml")
	write(t, path, "services: [fixture]\ncases: []\nskip: pretend\n")
	if _, err := loadPlan(path); err == nil || !strings.Contains(err.Error(), "field skip not found") {
		t.Fatalf("loadPlan error = %v", err)
	}
}

func TestDiscoverSelectsExactNamesAndRejectsMissingPlans(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"alpha", "alphabet"} {
		write(t, filepath.Join(root, name, "test", "cases.yaml"), `services: [fixture]
versions:
  - version: "1.0"
    digest: "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    default: true
cases: []
`)
	}
	plans, err := Discover(root, "", "alpha")
	if err != nil {
		t.Fatal(err)
	}
	if len(plans) != 1 || plans[0].Name != "alpha" {
		t.Fatalf("plans = %+v", plans)
	}
	if _, err := Discover(root, "", "missing"); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("missing plan error = %v", err)
	}
}

func TestVersionsRequireOneDefaultUniqueTagsAndExactDigests(t *testing.T) {
	tests := []struct {
		name     string
		versions []Version
		want     string
	}{
		{"missing", nil, "at least one"},
		{"no default", []Version{{Version: "1.0", Digest: testDigest("a")}}, "exactly one"},
		{"two defaults", []Version{
			{Version: "1.0", Digest: testDigest("a"), Default: true},
			{Version: "2.0", Digest: testDigest("b"), Default: true},
		}, "exactly one"},
		{"duplicate", []Version{
			{Version: "1.0", Digest: testDigest("a"), Default: true},
			{Version: "1.0", Digest: testDigest("b")},
		}, "duplicates"},
		{"bad tag", []Version{{Version: "bad/tag", Digest: testDigest("a"), Default: true}}, "image tag"},
		{"short digest", []Version{{Version: "1.0", Digest: "@sha256:abc", Default: true}}, "64 lowercase"},
		{"uppercase digest", []Version{{Version: "1.0", Digest: testDigest("A"), Default: true}}, "64 lowercase"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateVersions(test.versions)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validateVersions error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestMatrixPreservesPlanAndVersionOrder(t *testing.T) {
	plans := []PlanRef{
		{Name: "alpha", Versions: []Version{
			{Version: "2", Digest: testDigest("a"), Default: true},
			{Version: "1", Digest: testDigest("b")},
		}},
		{Name: "beta", Versions: []Version{
			{Version: "3", Digest: testDigest("c"), Default: true},
		}},
	}
	rows := Matrix(plans)
	if len(rows) != 3 ||
		rows[0].Pack != "alpha" || rows[0].Version != "2" ||
		rows[1].Pack != "alpha" || rows[1].Version != "1" ||
		rows[2].Pack != "beta" || rows[2].Version != "3" {
		t.Fatalf("Matrix() = %+v", rows)
	}
	if got := plans[0].DefaultVersion(); got.Version != "2" {
		t.Fatalf("DefaultVersion() = %+v", got)
	}
}

func TestRunReportsMalformedPlan(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "packs", "broken", "test", "cases.yaml"), "services: [")
	emisar := filepath.Join(root, "emisar")
	writeExecutable(t, emisar, "#!/bin/sh\nexit 0\n")
	var output bytes.Buffer
	_, err := Run(Config{
		Emisar: emisar, PacksDir: filepath.Join(root, "packs"),
		Reports: filepath.Join(root, "reports"), Out: &output,
	})
	if err == nil || !strings.Contains(err.Error(), "parse") {
		t.Fatalf("malformed plan error = %v", err)
	}
}

func testVersions() []Version {
	return []Version{{Version: "1.0", Digest: testDigest("a"), Default: true}}
}

func testDigest(character string) string {
	return "@sha256:" + strings.Repeat(character, 64)
}

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeExecutable(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o755); err != nil {
		t.Fatal(err)
	}
}
