package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

func loadScenario(path, id string) (scenario, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return scenario{}, err
	}
	var file scenarioFile
	if err := json.Unmarshal(data, &file); err != nil {
		return scenario{}, fmt.Errorf("parse scenarios: %w", err)
	}
	if file.Version != 1 {
		return scenario{}, fmt.Errorf("unsupported scenario version %d", file.Version)
	}
	for _, item := range file.Scenarios {
		if item.ID == id {
			if item.Prompt == "" {
				return scenario{}, fmt.Errorf("scenario %q has no prompt", id)
			}
			if len(item.AllowedTools) == 0 || len(item.AllowedActions) == 0 {
				return scenario{}, fmt.Errorf("scenario %q has no fail-closed tool and action allowlists", id)
			}
			if len(item.RequiredTools) == 0 || len(item.RequiredActions) == 0 {
				return scenario{}, fmt.Errorf("scenario %q has no required tool and action evidence", id)
			}
			allowedTools := stringSet(item.AllowedTools)
			for _, tool := range item.RequiredTools {
				if !allowedTools[tool] {
					return scenario{}, fmt.Errorf("scenario %q requires disallowed tool %q", id, tool)
				}
			}
			allowedActions := stringSet(item.AllowedActions)
			for _, action := range item.RequiredActions {
				if !allowedActions[action] {
					return scenario{}, fmt.Errorf("scenario %q requires disallowed action %q", id, action)
				}
			}
			return item, nil
		}
	}
	return scenario{}, fmt.Errorf("unknown scenario %q", id)
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
