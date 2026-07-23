package packtest

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
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
env:
  FIXTURE: present
defaults:
  expect:
    stdout_not_empty: true
cases:
  - action: example.inspect
    args: {count: 3, name: demo}
    expect:
      stdout_contains: [present, "count=3", "name=demo"]
  - action: example.mutate
    probes:
      - argv: ["`+filepath.Join(root, "probe")+`"]
        expect:
          stdout_contains: [changed]
    cleanup:
      - argv: ["`+filepath.Join(root, "cleanup")+`"]
`)
	emisar := filepath.Join(root, "emisar")
	writeExecutable(t, emisar, "#!/bin/sh\nprintf '%s\\n' \"$FIXTURE\" \"$@\"\nprintf changed > \""+filepath.Join(root, "state")+"\"\n")
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

func TestPlanValidationRejectsFalseCoverage(t *testing.T) {
	actions := map[string]actionDefinition{
		"example.read":   {ID: "example.read", Risk: "low"},
		"example.mutate": {ID: "example.mutate", Risk: "high"},
	}
	tests := []struct {
		name string
		plan Plan
		want string
	}{
		{"no services", Plan{Cases: []Case{{Action: "example.read", Expect: Expectation{StdoutNotEmpty: true}}}}, "services"},
		{"exit only", Plan{Services: []string{"fixture"}, Cases: []Case{{Action: "example.read"}}}, "only an exit-code"},
		{"unknown action", Plan{Services: []string{"fixture"}, Cases: []Case{{Action: "missing", Expect: Expectation{StdoutNotEmpty: true}}}}, "does not exist"},
		{"duplicate", Plan{Services: []string{"fixture"}, Cases: []Case{
			{Action: "example.read", Expect: Expectation{StdoutNotEmpty: true}},
			{Action: "example.read", Expect: Expectation{StdoutNotEmpty: true}},
		}}, "duplicates"},
		{"mutation without probe", Plan{Services: []string{"fixture"}, Cases: []Case{
			{Action: "example.mutate", Expect: Expectation{StdoutNotEmpty: true}, Cleanup: []Step{{Argv: []string{"true"}}}},
		}}, "state probe"},
		{"mutation without cleanup", Plan{Services: []string{"fixture"}, Cases: []Case{
			{Action: "example.mutate", Probes: []Step{{Argv: []string{"true"}, Expect: Expectation{StdoutNotEmpty: true}}}},
		}}, "needs cleanup"},
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
		write(t, filepath.Join(root, name, "test", "cases.yaml"), "services: [fixture]\ncases: []\n")
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
