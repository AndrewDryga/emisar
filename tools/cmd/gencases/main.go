// Command gencases regenerates packs/*/test/cases.json — one smoke-test case
// per action — from each pack's actions/*.yaml. The harness
// (dev/test-packs/harness.sh) consumes the JSON directly with jq; the files
// are GENERATED artifacts: never hand-edit one, change the policy tables
// (policy.go) or the action YAML and regenerate.
//
// Case derivation: args come from the action's first example (missing
// required args filled with safe defaults), else from required/defaulted arg
// schemas; read-only (risk: low) actions and the safeMutators expect exit 0;
// other mutators get a default `skip` (run deliberately via the harness) and
// tolerate exit [0,1]; actionArgs overrides args per action, with nil meaning
// "skip by default — unsafe against the shared SUT".
//
// Lives in the never-shipped tools module (see tools/cmd/depgate/main.go for
// the module rule): clients never need a test-case generator.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/andrewdryga/emisar/tools/internal/repo"
)

type argDef struct {
	Name       string `yaml:"name"`
	Type       string `yaml:"type"`
	Required   bool   `yaml:"required"`
	Default    any    `yaml:"default"`
	Validation struct {
		Enum    []any  `yaml:"enum"`
		Pattern string `yaml:"pattern"`
	} `yaml:"validation"`
}

type actionDef struct {
	ID       string   `yaml:"id"`
	Risk     string   `yaml:"risk"`
	Args     []argDef `yaml:"args"`
	Examples []struct {
		Args map[string]any `yaml:"args"`
	} `yaml:"examples"`
}

type testCase struct {
	Action string         `json:"action"`
	Args   map[string]any `json:"args"`
	// ExpectExit is an int, a []int of acceptable codes, or absent (nil) for
	// the skipped-override cases. omitempty on an any drops only nil — a
	// present int 0 still serializes.
	ExpectExit any    `json:"expect_exit,omitempty"`
	Skip       string `json:"skip,omitempty"`
}

type casesFile struct {
	Defaults struct {
		Env map[string]string `json:"env"`
	} `json:"defaults"`
	Cases []testCase `json:"cases"`
}

// safeDefault picks a benign literal for one arg schema.
func safeDefault(arg argDef) any {
	if arg.Default != nil {
		return arg.Default
	}
	switch arg.Type {
	case "integer":
		switch arg.Name {
		case "pid":
			return 1
		case "port":
			return 80
		case "limit", "count", "top", "n", "max":
			return 10
		}
		return 0
	case "boolean":
		return false
	}
	if len(arg.Validation.Enum) > 0 {
		return arg.Validation.Enum[0]
	}
	if strings.Contains(arg.Validation.Pattern, "^/") {
		return "/etc/hostname"
	}
	return "smoke"
}

// deriveArgs picks the case's args from the action definition: the first
// example (missing required args filled), else safe defaults for every
// required or defaulted arg.
func deriveArgs(action actionDef) map[string]any {
	if len(action.Examples) > 0 {
		args := map[string]any{}
		for k, v := range action.Examples[0].Args {
			args[k] = v
		}
		for _, a := range action.Args {
			if a.Required {
				if _, ok := args[a.Name]; !ok {
					args[a.Name] = safeDefault(a)
				}
			}
		}
		return args
	}
	args := map[string]any{}
	for _, a := range action.Args {
		if a.Required || a.Default != nil {
			args[a.Name] = safeDefault(a)
		}
	}
	return args
}

// emitPack builds the pack's cases file, or nil when it has no actions/ dir.
func emitPack(packDir string) (*casesFile, error) {
	actionFiles, err := filepath.Glob(filepath.Join(packDir, "actions", "*.yaml"))
	if err != nil || actionFiles == nil {
		return nil, err
	}
	sort.Strings(actionFiles)

	out := &casesFile{Cases: []testCase{}}
	out.Defaults.Env = map[string]string{}
	if env, ok := packEnv[filepath.Base(packDir)]; ok {
		out.Defaults.Env = env
	}

	for _, path := range actionFiles {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var action actionDef
		if err := yaml.Unmarshal(data, &action); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: %s: yaml parse error: %v\n", path, err)
			continue
		}
		if action.ID == "" {
			continue
		}
		risk := action.Risk
		if risk == "" {
			risk = "low"
		}

		c := testCase{Action: action.ID}
		if override, listed := actionArgs[action.ID]; listed {
			if override == nil {
				c.Args = deriveArgs(action)
				c.Skip = fmt.Sprintf("mutator skipped by default (%s); set --include=%s to run", risk, action.ID)
				out.Cases = append(out.Cases, c)
				continue
			}
			c.Args = override
		} else {
			c.Args = deriveArgs(action)
		}

		// Read-only baseline (and vetted-safe mutators): expect exit 0. Other
		// mutators tolerate [0,1] — their preconditions are fragile — and are
		// skipped by default.
		if risk == "low" || safeMutators[action.ID] {
			c.ExpectExit = 0
		} else {
			c.ExpectExit = []int{0, 1}
			c.Skip = fmt.Sprintf("mutator skipped by default (%s)", risk)
		}
		out.Cases = append(out.Cases, c)
	}
	return out, nil
}

func main() {
	root, err := repo.Root()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}
	packsRoot := filepath.Join(root, "packs")

	entries, err := os.ReadDir(packsRoot)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}

	nPacks, nCases := 0, 0
	for _, entry := range entries {
		packDir := filepath.Join(packsRoot, entry.Name())
		if _, err := os.Stat(filepath.Join(packDir, "pack.yaml")); err != nil {
			continue
		}
		result, err := emitPack(packDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %s: %v\n", entry.Name(), err)
			os.Exit(2)
		}
		if result == nil {
			continue
		}
		if err := os.MkdirAll(filepath.Join(packDir, "test"), 0o755); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(2)
		}
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(2)
		}
		outPath := filepath.Join(packDir, "test", "cases.json")
		if err := os.WriteFile(outPath, append(data, '\n'), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(2)
		}
		nPacks++
		nCases += len(result.Cases)
		fmt.Fprintf(os.Stderr, "%s: %d cases\n", entry.Name(), len(result.Cases))
	}
	fmt.Fprintf(os.Stderr, "\nTotal: %d packs, %d cases\n", nPacks, nCases)
}
