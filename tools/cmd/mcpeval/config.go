package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

const (
	corpusDevelopment  = "development"
	corpusHeldOut      = "held_out"
	outcomePositive    = "positive"
	outcomeNoAction    = "no_action"
	maxCorpusScenarios = 8
)

func loadScenario(path, id string) (scenarioFile, scenario, error) {
	file, err := loadCorpus(path, false)
	if err != nil {
		return scenarioFile{}, scenario{}, err
	}
	for _, item := range file.Scenarios {
		if item.ID == id {
			return file, normalizedScenario(item), nil
		}
	}
	return scenarioFile{}, scenario{}, fmt.Errorf("unknown scenario %q", id)
}

func loadCorpus(path string, requireHeldOut bool) (scenarioFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return scenarioFile{}, err
	}
	var file scenarioFile
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&file); err != nil {
		return scenarioFile{}, fmt.Errorf("parse scenarios: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err == nil {
		return scenarioFile{}, fmt.Errorf("parse scenarios: trailing JSON")
	} else if !errors.Is(err, io.EOF) {
		return scenarioFile{}, fmt.Errorf("parse scenarios: %w", err)
	}
	if err := validateCorpus(file, requireHeldOut); err != nil {
		return scenarioFile{}, err
	}
	return file, nil
}

func validateCorpus(file scenarioFile, requireHeldOut bool) error {
	if file.Version != 1 && file.Version != 2 {
		return fmt.Errorf("unsupported scenario version %d", file.Version)
	}
	if file.Kind == "" {
		file.Kind = corpusDevelopment
	}
	if file.Kind != corpusDevelopment && file.Kind != corpusHeldOut {
		return fmt.Errorf("unsupported corpus kind %q", file.Kind)
	}
	if requireHeldOut && file.Kind != corpusHeldOut {
		return fmt.Errorf("release qualification requires a held_out corpus")
	}
	if file.Kind == corpusHeldOut && strings.TrimSpace(file.PartitionID) == "" {
		return fmt.Errorf("held_out corpus has no partition_id")
	}
	if len(file.Scenarios) == 0 {
		return fmt.Errorf("corpus has no scenarios")
	}
	if len(file.Scenarios) > maxCorpusScenarios {
		return fmt.Errorf("corpus has %d scenarios, limit is %d", len(file.Scenarios), maxCorpusScenarios)
	}

	ids := map[string]bool{}
	positiveGroups := map[string]bool{}
	negativeGroups := map[string]bool{}
	positives, negatives := 0, 0
	for _, item := range file.Scenarios {
		item = normalizedScenario(item)
		if ids[item.ID] {
			return fmt.Errorf("duplicate scenario %q", item.ID)
		}
		ids[item.ID] = true
		if err := validateScenario(item, file.Kind == corpusHeldOut); err != nil {
			return err
		}
		switch item.ExpectedOutcome {
		case outcomePositive:
			positives++
			positiveGroups[item.IntentGroup] = true
		case outcomeNoAction:
			negatives++
			negativeGroups[item.IntentGroup] = true
		}
	}
	if file.Kind == corpusHeldOut {
		if positives < 2 || negatives < 2 {
			return fmt.Errorf("held_out corpus needs at least two positive and two no_action scenarios")
		}
		if len(positiveGroups) < 2 || len(negativeGroups) < 2 {
			return fmt.Errorf("held_out corpus must split positive and no_action cases across at least two intent groups each")
		}
	}
	return nil
}

func validateScenario(item scenario, heldOut bool) error {
	if item.ID == "" || item.Prompt == "" {
		return fmt.Errorf("scenario %q has no id or prompt", item.ID)
	}
	if heldOut && item.IntentGroup == "" {
		return fmt.Errorf("held_out scenario %q has no intent_group", item.ID)
	}
	if len(item.AllowedTools) == 0 || len(item.RequiredTools) == 0 {
		return fmt.Errorf("scenario %q has no fail-closed tool allowlist or required tool evidence", item.ID)
	}
	allowedTools := stringSet(item.AllowedTools)
	for _, tool := range item.RequiredTools {
		if !allowedTools[tool] {
			return fmt.Errorf("scenario %q requires disallowed tool %q", item.ID, tool)
		}
	}
	for _, tool := range item.AllowedTools {
		if tool != "run_action" && mutationTools[tool] {
			return fmt.Errorf("scenario %q allows unsupported mutation tool %q", item.ID, tool)
		}
	}
	allowedActions := stringSet(item.AllowedActions)
	switch item.ExpectedOutcome {
	case outcomePositive:
		if len(item.AllowedActions) == 0 || len(item.RequiredActions) == 0 ||
			len(item.RequiredSearchActions) == 0 {
			return fmt.Errorf("positive scenario %q has no action, completion, or recall@5 evidence", item.ID)
		}
		if heldOut && (len(item.AllowedPackRefs) == 0 || len(item.AllowedRunnerRefs) == 0) {
			return fmt.Errorf("held_out positive scenario %q has no exact pack or runner ref allowlist", item.ID)
		}
	case outcomeNoAction:
		if len(item.AllowedActions) != 0 || len(item.RequiredActions) != 0 ||
			len(item.RequiredSearchActions) != 0 {
			return fmt.Errorf("no_action scenario %q must not allow or require an action", item.ID)
		}
		if !allowedTools["find_actions"] || !stringSet(item.RequiredTools)["find_actions"] {
			return fmt.Errorf("no_action scenario %q must require find_actions", item.ID)
		}
	default:
		return fmt.Errorf("scenario %q has unsupported expected_outcome %q", item.ID, item.ExpectedOutcome)
	}
	for _, groups := range [][][]string{item.RequiredActions, item.RequiredSearchActions} {
		for _, group := range groups {
			if len(group) == 0 {
				return fmt.Errorf("scenario %q has an empty action group", item.ID)
			}
			for _, action := range group {
				if !allowedActions[action] {
					return fmt.Errorf("scenario %q requires disallowed action %q", item.ID, action)
				}
			}
		}
	}
	return nil
}

func normalizedScenario(item scenario) scenario {
	if item.ExpectedOutcome == "" {
		item.ExpectedOutcome = outcomePositive
	}
	if len(item.RequiredSearchActions) == 0 && item.ExpectedOutcome == outcomePositive {
		item.RequiredSearchActions = item.RequiredActions
	}
	return item
}

func corpusDigest(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return fmt.Sprintf("sha256:%x", sum), nil
}

func corpusKind(file scenarioFile) string {
	if file.Kind == "" {
		return corpusDevelopment
	}
	return file.Kind
}

// prepareWorkspace creates a throwaway directory outside the repository and
// makes it its own Git root, so neither agent can walk up into the real
// checkout (Codex also refuses to run outside a repository).
func prepareWorkspace() (string, error) {
	path, err := os.MkdirTemp("", "mcpeval-")
	if err != nil {
		return "", err
	}
	command := exec.Command("git", "init", "--quiet", path)
	if output, err := command.CombinedOutput(); err != nil {
		_ = os.RemoveAll(path)
		return "", fmt.Errorf("initialize isolated repository: %w: %s", err, output)
	}
	return path, nil
}
