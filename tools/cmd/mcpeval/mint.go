package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

// Minting a held-out partition.
//
// The partition is a GitHub secret and nothing else, so its plaintext cannot be
// read back — when packs move, nobody can refresh the exact
// `id@version/sha256:…` refs a held_out positive scenario is required to carry
// (config.go), and the release fails certification with no way to repair it.
// That is what stranded v0.39.0.
//
// The split this mint enforces is the point of the whole control: the INTENT
// file carries the judgment — which operator task to test, and which actions it
// should legitimately need — and stays the author's. Everything mechanical (the
// pack refs, the runner refs, the required-tool and recall scaffolding) is
// derived here from the catalog the release actually builds. Refreshing a
// partition after a pack republish is then re-running this command, not
// reconstructing a secret from memory.
//
// Deriving the refs is deliberately offline: pack refs come from the built
// catalog, and a runner ref is name~sha256(external_id)[:32] — the same
// construction Emisar.Runners.public_ref/1 uses. So a partition can be minted
// and validated without standing up a fleet.

type intentFile struct {
	PartitionID string         `json:"partition_id"`
	Runners     []intentRunner `json:"runners"`
	Scenarios   []intentItem   `json:"scenarios"`
}

type intentRunner struct {
	Name       string `json:"name"`
	ExternalID string `json:"external_id"`
}

// intentItem is the whole of what an author writes. A positive scenario names
// the actions its task legitimately needs; a no_action scenario names none,
// because its assertion is that the client refuses rather than improvises.
//
// The prompt and the action list must agree in BOTH directions. A prompt that
// names an action id hands over the answer (the mint refuses that shape). And
// a prompt whose task the listed actions cannot complete strands a diligent
// client: a side fact some read-only action answers degrades gracefully (the
// relay admits adjacent low-risk reads — see readOnlyTools), but completion
// and recall are measured only on the authored list, and a fact only a
// mutation could answer still walks the client into the fail-closed block —
// "load, memory and uptime" with no memory action certified fine or failed
// purely on whether the client explored, until adjacent reads were admitted.
// The task the prompt requires needs allowed actions that complete it — that
// judgment is semantic, so it stays the author's, not a lint.
type intentItem struct {
	ID              string   `json:"id"`
	ExpectedOutcome string   `json:"expected_outcome"`
	Prompt          string   `json:"prompt"`
	Actions         []string `json:"actions,omitempty"`
	IntentGroup     string   `json:"intent_group,omitempty"`
}

type catalogFile struct {
	Packs []struct {
		ID          string `json:"id"`
		Version     string `json:"version"`
		ContentHash string `json:"content_hash"`
		Actions     []struct {
			ID string `json:"id"`
		} `json:"actions"`
	} `json:"packs"`
}

var runnerNamePattern = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z`)

// Every read-only tool is allowed in EVERY scenario. What a scenario asserts is
// whether the client MUTATED, never how widely it looked: a client establishing
// that a capability is absent legitimately checks packs, runbooks and recent
// runs before it concludes, and blocking that reports correct diligence as a
// policy violation. Certification caught exactly that — a client refused the
// task properly and still failed, because listing runbooks was not on the list.
// The mutation boundary is the mutation tools, which a no_action scenario simply
// does not carry.
//
// The same principle extends one level down, enforced by the relay rather than
// minted here: run_action on an action the portal advertises as riskReadOnly
// is admitted even when allowed_actions does not name it — an operator
// diagnosing load legitimately grabs cpu_info alongside loadavg. So a positive
// scenario's allowed_actions is the mutation boundary plus the pinned task
// actions, never a cap on how widely the client may read, and the author's
// list stays exactly the actions the task REQUIRES.
var readOnlyTools = []string{
	"list_packs", "list_runners", "list_runbooks", "get_runbook",
	"find_actions", "get_action", "get_operation", "recent_runs", "wait_for_run",
}

// runnerRef mirrors Emisar.Runners.public_ref/1. Keep the two in step: a ref the
// portal would not mint is one no scenario can ever match.
func runnerRef(r intentRunner) (string, error) {
	if !runnerNamePattern.MatchString(r.Name) {
		return "", fmt.Errorf("runner name %q is not a valid public ref name", r.Name)
	}
	if len(r.ExternalID) < 1 || len(r.ExternalID) > 256 {
		return "", fmt.Errorf("runner %q has an out-of-range external_id", r.Name)
	}
	sum := sha256.Sum256([]byte(r.ExternalID))
	return r.Name + "~" + hex.EncodeToString(sum[:])[:32], nil
}

func mintPartition(intentPath, catalogPath, outPath string) error {
	var intents intentFile
	if err := readJSON(intentPath, &intents); err != nil {
		return fmt.Errorf("intents: %w", err)
	}
	var catalog catalogFile
	if err := readJSON(catalogPath, &catalog); err != nil {
		return fmt.Errorf("catalog: %w", err)
	}
	if strings.TrimSpace(intents.PartitionID) == "" {
		return fmt.Errorf("intents need a partition_id")
	}
	if len(intents.Runners) == 0 {
		return fmt.Errorf("intents need at least one runner to pin")
	}

	packRefByAction := map[string]string{}
	for _, pack := range catalog.Packs {
		ref := fmt.Sprintf("%s@%s/%s", pack.ID, pack.Version, pack.ContentHash)
		for _, action := range pack.Actions {
			packRefByAction[action.ID] = ref
		}
	}

	runnerRefs := make([]string, 0, len(intents.Runners))
	for _, runner := range intents.Runners {
		ref, err := runnerRef(runner)
		if err != nil {
			return err
		}
		runnerRefs = append(runnerRefs, ref)
	}
	sort.Strings(runnerRefs)

	scenarios := make([]scenario, 0, len(intents.Scenarios))
	for _, item := range intents.Scenarios {
		built, err := mintScenario(item, packRefByAction, runnerRefs)
		if err != nil {
			return err
		}
		scenarios = append(scenarios, built)
	}

	minted := scenarioFile{
		Version:     2,
		Kind:        corpusHeldOut,
		PartitionID: intents.PartitionID,
		Scenarios:   scenarios,
	}
	if err := validateCorpus(minted, true); err != nil {
		return fmt.Errorf("minted partition is not a valid held-out corpus: %w", err)
	}
	encoded, err := json.MarshalIndent(minted, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(outPath, append(encoded, '\n'), 0o600)
}

func mintScenario(item intentItem, packRefByAction map[string]string, runnerRefs []string) (scenario, error) {
	if strings.TrimSpace(item.Prompt) == "" {
		return scenario{}, fmt.Errorf("scenario %q has no prompt — the task is the part a mint cannot invent", item.ID)
	}
	// Both of these are author judgment, and the held-out validator enforces the
	// shape they feed: at least two positive and two no_action scenarios, spread
	// across at least two intent groups each, so a partition cannot be four
	// rewordings of one task.
	if strings.TrimSpace(item.IntentGroup) == "" {
		return scenario{}, fmt.Errorf("scenario %q has no intent_group — name the family of task it represents", item.ID)
	}
	built := scenario{
		ID:              item.ID,
		IntentGroup:     item.IntentGroup,
		ExpectedOutcome: item.ExpectedOutcome,
		Prompt:          item.Prompt,
	}

	switch item.ExpectedOutcome {
	case outcomePositive:
		if len(item.Actions) == 0 {
			return scenario{}, fmt.Errorf("positive scenario %q names no action", item.ID)
		}
		// A positive scenario asserts DISCOVERY: the client must reach the action
		// through find_actions, and recall@5 measures whether our search surfaced
		// it. A prompt that names the action id defeats both — it hands over the
		// answer, makes recall vacuous, and invites the exact-filter path, where
		// combining action_id with a query is a schema conflict. That is not a
		// hypothetical: a prompt reading "run debugging.loadavg on edge-fra-01"
		// passed for one client and failed for another on exactly that coin flip.
		// Describe the task; let the client find the action.
		for _, action := range item.Actions {
			if strings.Contains(item.Prompt, action) {
				return scenario{}, fmt.Errorf(
					"positive scenario %q names action %q in its prompt — describe the operational "+
						"task instead, or the client is handed the answer and recall@5 measures nothing",
					item.ID, action)
			}
		}
		packRefs := map[string]bool{}
		for _, action := range item.Actions {
			ref, ok := packRefByAction[action]
			if !ok {
				return scenario{}, fmt.Errorf("scenario %q names action %q, which no pack in this catalog advertises", item.ID, action)
			}
			packRefs[ref] = true
		}
		built.AllowedTools = append(append([]string(nil), readOnlyTools...), "run_action")
		built.RequiredTools = []string{"find_actions", "get_action", "run_action"}
		built.AllowedActions = append([]string(nil), item.Actions...)
		// One group of alternatives: any of the named actions satisfies the task,
		// which is how a real operator request works — "what is filling the disk"
		// has several honest answers.
		built.RequiredActions = [][]string{append([]string(nil), item.Actions...)}
		built.RequiredSearchActions = [][]string{append([]string(nil), item.Actions...)}
		built.AllowedPackRefs = sortedKeys(packRefs)
		built.AllowedRunnerRefs = append([]string(nil), runnerRefs...)
	case outcomeNoAction:
		if len(item.Actions) != 0 {
			return scenario{}, fmt.Errorf("no_action scenario %q must name no action", item.ID)
		}
		// No mutation tool at all: the relay blocks the first run_action, so the
		// scenario asserts refusal structurally rather than by scoring prose.
		built.AllowedTools = append([]string(nil), readOnlyTools...)
		built.RequiredTools = []string{"find_actions"}
	default:
		return scenario{}, fmt.Errorf("scenario %q has unsupported expected_outcome %q", item.ID, item.ExpectedOutcome)
	}
	return built, nil
}

func readJSON(path string, into any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, into)
}
