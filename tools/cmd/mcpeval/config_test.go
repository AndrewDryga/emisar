package main

import (
	"fmt"
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
	_, got, err := loadScenario(path, "health")
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
		if _, _, err := loadScenario(path, "health"); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}

func TestCommittedScenarioCorpusLoads(t *testing.T) {
	file, got, err := loadScenario(filepath.Join("..", "..", "mcpeval", "scenarios.json"), "read-only-host-health")
	if err != nil {
		t.Fatal(err)
	}
	if corpusKind(file) != corpusDevelopment || len(got.AllowedTools) != 10 || len(got.RequiredActions) != 3 {
		t.Fatalf("committed scenario = %#v", got)
	}
}

func TestHeldOutCorpusRequiresPositiveNegativeIntentPartitions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "held-out.json")
	data := `{
	  "version": 2,
	  "kind": "held_out",
	  "partition_id": "release-1",
	  "scenarios": [
	    {"id":"p1","intent_group":"health","expected_outcome":"positive","prompt":"one","allowed_tools":["find_actions","run_action"],"allowed_actions":["linux.uptime"],"allowed_pack_refs":["linux-core@1/sha256:abc"],"allowed_runner_refs":["edge~a"],"required_tools":["find_actions","run_action"],"required_actions":[["linux.uptime"]],"required_search_actions":[["linux.uptime"]]},
	    {"id":"p2","intent_group":"storage","expected_outcome":"positive","prompt":"two","allowed_tools":["find_actions","run_action"],"allowed_actions":["linux.disk_usage"],"allowed_pack_refs":["linux-core@1/sha256:abc"],"allowed_runner_refs":["edge~a"],"required_tools":["find_actions","run_action"],"required_actions":[["linux.disk_usage"]],"required_search_actions":[["linux.disk_usage"]]},
	    {"id":"n1","intent_group":"payroll","expected_outcome":"no_action","prompt":"three","allowed_tools":["find_actions"],"required_tools":["find_actions"]},
	    {"id":"n2","intent_group":"hr","expected_outcome":"no_action","prompt":"four","allowed_tools":["find_actions"],"required_tools":["find_actions"]}
	  ]
	}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := loadCorpus(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if file.PartitionID != "release-1" {
		t.Fatalf("held-out corpus = %#v", file)
	}

	file.Scenarios = file.Scenarios[:3]
	if err := validateCorpus(file, true); err == nil {
		t.Fatal("undersized held-out corpus was accepted")
	}

	unsafe := file.Scenarios[0]
	unsafe.AllowedTools = append(unsafe.AllowedTools, "execute_runbook")
	if err := validateScenario(unsafe, true); err == nil {
		t.Fatal("held-out scenario with an unscored mutation tool was accepted")
	}

	oversized := file
	for len(oversized.Scenarios) <= maxCorpusScenarios {
		next := oversized.Scenarios[0]
		next.ID = fmt.Sprintf("extra-%d", len(oversized.Scenarios))
		oversized.Scenarios = append(oversized.Scenarios, next)
	}
	if err := validateCorpus(oversized, true); err == nil {
		t.Fatal("oversized held-out corpus was accepted")
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
