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
		packRefs := map[string]bool{}
		for _, action := range item.Actions {
			ref, ok := packRefByAction[action]
			if !ok {
				return scenario{}, fmt.Errorf("scenario %q names action %q, which no pack in this catalog advertises", item.ID, action)
			}
			packRefs[ref] = true
		}
		built.AllowedTools = []string{"list_runners", "find_actions", "get_action", "run_action", "wait_for_run"}
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
		built.AllowedTools = []string{"list_runners", "find_actions", "get_action"}
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
