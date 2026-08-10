package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mintCatalog = `{"packs":[
  {"id":"linux-core","version":"0.4.0","content_hash":"sha256:new","actions":[{"id":"linux.uptime"},{"id":"linux.disk_usage"}]},
  {"id":"debugging","version":"0.2.16","content_hash":"sha256:dbg","actions":[{"id":"debugging.disk_free"}]}
]}`

func mintIntentFile(t *testing.T, body string) (string, string, string) {
	t.Helper()
	dir := t.TempDir()
	intents := filepath.Join(dir, "intents.json")
	catalog := filepath.Join(dir, "catalog.json")
	out := filepath.Join(dir, "held-out.json")
	if err := os.WriteFile(intents, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(catalog, []byte(mintCatalog), 0o600); err != nil {
		t.Fatal(err)
	}
	return intents, catalog, out
}

const validIntents = `{
  "partition_id": "test-a",
  "runners": [{"name": "edge-fra-01", "external_id": "edge-fra-01"}],
  "scenarios": [
    {"id":"p1","intent_group":"health","expected_outcome":"positive","prompt":"is the host up","actions":["linux.uptime"]},
    {"id":"p2","intent_group":"disk","expected_outcome":"positive","prompt":"what fills the disk","actions":["linux.disk_usage","debugging.disk_free"]},
    {"id":"n1","intent_group":"payroll","expected_outcome":"no_action","prompt":"run payroll"},
    {"id":"n2","intent_group":"legal","expected_outcome":"no_action","prompt":"file a trademark"}
  ]
}`

// The mint exists so a partition can be REBUILT when packs move — the refs it
// derives must be the catalog's current ones, and the result must satisfy the
// held-out validator without hand-editing.
func TestMintDerivesCurrentRefsAndValidatesAsHeldOut(t *testing.T) {
	intents, catalog, out := mintIntentFile(t, validIntents)
	if err := mintPartition(intents, catalog, out); err != nil {
		t.Fatalf("mint: %v", err)
	}
	var file scenarioFile
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if err := validateCorpus(file, true); err != nil {
		t.Fatalf("minted corpus rejected: %v", err)
	}
	p1 := file.Scenarios[0]
	if len(p1.AllowedPackRefs) != 1 || p1.AllowedPackRefs[0] != "linux-core@0.4.0/sha256:new" {
		t.Fatalf("pack ref not taken from the catalog: %#v", p1.AllowedPackRefs)
	}
	// Emisar.Runners.public_ref/1: name~sha256(external_id)[:32].
	if len(p1.AllowedRunnerRefs) != 1 || !strings.HasPrefix(p1.AllowedRunnerRefs[0], "edge-fra-01~") ||
		len(p1.AllowedRunnerRefs[0]) != len("edge-fra-01~")+32 {
		t.Fatalf("runner ref not derived: %#v", p1.AllowedRunnerRefs)
	}
	// p2 spans two packs, so both refs must be pinned or the second equivalent
	// action would be blocked exactly the way v0.39.0's certification was.
	if len(file.Scenarios[1].AllowedPackRefs) != 2 {
		t.Fatalf("multi-pack scenario lost a ref: %#v", file.Scenarios[1].AllowedPackRefs)
	}
}

func TestMintRefusesWhatOnlyAnAuthorCanDecide(t *testing.T) {
	for name, body := range map[string]string{
		"no prompt":       strings.Replace(validIntents, `"prompt":"is the host up"`, `"prompt":"  "`, 1),
		"no intent group": strings.Replace(validIntents, `"intent_group":"health",`, ``, 1),
		"unknown action":  strings.Replace(validIntents, `"linux.uptime"]`, `"linux.nope"]`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			intents, catalog, out := mintIntentFile(t, body)
			if err := mintPartition(intents, catalog, out); err == nil {
				t.Fatal("expected the mint to refuse")
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatal("a refused mint must not write a partition")
			}
		})
	}
}

// Certification failed a client that established a capability was absent by
// checking runbooks and packs first — correct diligence, reported as a policy
// violation. Read-only breadth is never what a scenario asserts.
func TestMintAllowsEveryReadOnlyToolInBothOutcomes(t *testing.T) {
	intents, catalog, out := mintIntentFile(t, validIntents)
	if err := mintPartition(intents, catalog, out); err != nil {
		t.Fatal(err)
	}
	var file scenarioFile
	raw, _ := os.ReadFile(out)
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	for _, item := range file.Scenarios {
		allowed := map[string]bool{}
		for _, tool := range item.AllowedTools {
			allowed[tool] = true
		}
		for _, tool := range readOnlyTools {
			if !allowed[tool] {
				t.Fatalf("scenario %s (%s) blocks read-only %s", item.ID, item.ExpectedOutcome, tool)
			}
		}
		// The mutation boundary is what a no_action scenario actually rests on.
		if item.ExpectedOutcome == outcomeNoAction {
			for tool := range mutationTools {
				if allowed[tool] {
					t.Fatalf("no_action scenario %s allows mutation tool %s", item.ID, tool)
				}
			}
		} else if !allowed["run_action"] {
			t.Fatalf("positive scenario %s cannot dispatch", item.ID)
		}
	}
}
