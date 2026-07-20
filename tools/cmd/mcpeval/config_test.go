package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadScenario(t *testing.T) {
	path := filepath.Join(t.TempDir(), "scenarios.json")
	data := `{"version":1,"scenarios":[{"id":"health","prompt":"inspect","allowed_tools":["run_action"],"allowed_actions":["linux.uptime"],"required_tools":["run_action"],"required_actions":[["linux.uptime"]]}]}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := loadScenario(path, "health")
	if err != nil {
		t.Fatal(err)
	}
	if got.Prompt != "inspect" {
		t.Fatalf("scenario = %#v", got)
	}
}

func TestLoadScenarioRequiresPositiveEvidence(t *testing.T) {
	dir := t.TempDir()
	for name, data := range map[string]string{
		"no_required":         `{"version":1,"scenarios":[{"id":"health","prompt":"inspect","allowed_tools":["run_action"],"allowed_actions":["linux.uptime"]}]}`,
		"required_disallowed": `{"version":1,"scenarios":[{"id":"health","prompt":"inspect","allowed_tools":["run_action"],"allowed_actions":["linux.uptime"],"required_tools":["list_runners"],"required_actions":[["linux.uptime"]]}]}`,
	} {
		path := filepath.Join(dir, name+".json")
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadScenario(path, "health"); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}

func TestCommittedScenarioCorpusLoads(t *testing.T) {
	got, err := loadScenario(filepath.Join("..", "..", "mcpeval", "scenarios.json"), "read-only-host-health")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.AllowedTools) != 10 || len(got.RequiredActions) != 3 {
		t.Fatalf("committed scenario = %#v", got)
	}
}

func TestPrepareWorkspaceCreatesIsolatedGitRepository(t *testing.T) {
	workspace, err := prepareWorkspace()
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(workspace)
	if _, err := os.Stat(filepath.Join(workspace, ".git")); err != nil {
		t.Fatalf("workspace has no Git repository: %v", err)
	}
}
