// Package packtest executes pack-owned behavioral plans against disposable
// Compose services. Pack validation covers every action contract; this package
// counts only cases that exercise observable behavior as integration coverage.
package packtest

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

type Expectation struct {
	Exit           []int    `yaml:"exit,omitempty"`
	StdoutNotEmpty bool     `yaml:"stdout_not_empty,omitempty"`
	StdoutContains []string `yaml:"stdout_contains,omitempty"`
	StderrContains []string `yaml:"stderr_contains,omitempty"`
}

type Step struct {
	Name       string            `yaml:"name,omitempty"`
	Argv       []string          `yaml:"argv"`
	Env        map[string]string `yaml:"env,omitempty"`
	Expect     Expectation       `yaml:"expect,omitempty"`
	RetryFor   string            `yaml:"retry_for,omitempty"`
	RetryEvery string            `yaml:"retry_every,omitempty"`
}

type Case struct {
	Action  string         `yaml:"action"`
	Args    map[string]any `yaml:"args,omitempty"`
	Reason  string         `yaml:"reason,omitempty"`
	Expect  Expectation    `yaml:"expect,omitempty"`
	Arrange []Step         `yaml:"arrange,omitempty"`
	Probes  []Step         `yaml:"probes,omitempty"`
	Cleanup []Step         `yaml:"cleanup,omitempty"`
}

type Defaults struct {
	Expect Expectation `yaml:"expect,omitempty"`
}

type Plan struct {
	Services []string          `yaml:"services"`
	Env      map[string]string `yaml:"env,omitempty"`
	Defaults Defaults          `yaml:"defaults,omitempty"`
	Cases    []Case            `yaml:"cases"`
}

type PlanRef struct {
	Name     string
	Path     string
	Services []string
}

type Config struct {
	Emisar   string
	PacksDir string
	Config   string
	Reports  string
	Pattern  string
	Names    []string
	Out      io.Writer
	BaseEnv  []string
}

type Totals struct {
	Pass, Fail                  int
	PacksRun, PacksFailed       int
	Actions, Behavior, Contract int
}

func (totals Totals) Failed() bool { return totals.Fail != 0 || totals.PacksFailed != 0 }

type actionDefinition struct {
	ID   string `yaml:"id"`
	Risk string `yaml:"risk"`
}

type commandResult struct {
	exitCode int
	stdout   string
	stderr   string
}

func Discover(packsDir, pattern string, names ...string) ([]PlanRef, error) {
	if pattern != "" && len(names) > 0 {
		return nil, fmt.Errorf("pack pattern and exact names are mutually exclusive")
	}
	wanted := make(map[string]bool, len(names))
	for _, name := range names {
		if name == "" || filepath.Base(name) != name || name == "." {
			return nil, fmt.Errorf("invalid pack name %q", name)
		}
		wanted[name] = true
	}
	paths, err := filepath.Glob(filepath.Join(packsDir, "*", "test", "cases.yaml"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	plans := make([]PlanRef, 0, len(paths))
	for _, path := range paths {
		name := filepath.Base(filepath.Dir(filepath.Dir(path)))
		if pattern != "" && !strings.Contains(name, pattern) {
			continue
		}
		if len(wanted) > 0 && !wanted[name] {
			continue
		}
		plan, err := loadPlan(path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		plans = append(plans, PlanRef{Name: name, Path: path, Services: plan.Services})
	}
	if len(plans) == 0 {
		if len(wanted) > 0 {
			missing := append([]string(nil), names...)
			sort.Strings(missing)
			return nil, fmt.Errorf("packs have no behavioral plan: %s", strings.Join(missing, ", "))
		}
		return nil, fmt.Errorf("no behavioral pack plans matched the selection")
	}
	if len(wanted) > 0 && len(plans) != len(wanted) {
		found := make(map[string]bool, len(plans))
		for _, plan := range plans {
			found[plan.Name] = true
		}
		var missing []string
		for name := range wanted {
			if !found[name] {
				missing = append(missing, name)
			}
		}
		sort.Strings(missing)
		return nil, fmt.Errorf("packs have no behavioral plan: %s", strings.Join(missing, ", "))
	}
	return plans, nil
}

func Run(config Config) (Totals, error) {
	config = withDefaults(config)
	if info, err := os.Stat(config.Emisar); err != nil || info.Mode()&0o111 == 0 {
		return Totals{}, fmt.Errorf("emisar binary not found or executable at %s", config.Emisar)
	}
	if err := os.MkdirAll(config.Reports, 0o755); err != nil {
		return Totals{}, err
	}
	plans, err := Discover(config.PacksDir, config.Pattern, config.Names...)
	if err != nil {
		return Totals{}, err
	}

	totals := Totals{}
	for _, ref := range plans {
		fmt.Fprintf(config.Out, "================================\nPack: %s\n================================\n", ref.Name)
		var log bytes.Buffer
		writer := io.MultiWriter(config.Out, &log)
		packTotals, runErr := runPack(config, ref, writer)
		totals.Pass += packTotals.Pass
		totals.Fail += packTotals.Fail
		totals.Actions += packTotals.Actions
		totals.Behavior += packTotals.Behavior
		totals.Contract += packTotals.Contract
		totals.PacksRun++
		if runErr != nil || packTotals.Fail != 0 {
			totals.PacksFailed++
		}
		if runErr != nil {
			fmt.Fprintf(writer, "ERROR %s - %v\n", ref.Name, runErr)
		}
		if err := os.WriteFile(filepath.Join(config.Reports, ref.Name+".log"), log.Bytes(), 0o644); err != nil {
			return totals, err
		}
	}

	fmt.Fprintf(config.Out, "\n===============================\nGRAND TOTAL\n===============================\nPacks run:        %d\nPacks failed:     %d\nBehavior passed:  %d\nBehavior failed:  %d\nActions total:    %d\nBehavior covered: %d\nContract only:    %d\n",
		totals.PacksRun, totals.PacksFailed, totals.Pass, totals.Fail,
		totals.Actions, totals.Behavior, totals.Contract)
	if totals.Failed() {
		return totals, fmt.Errorf("pack behavior tests failed")
	}
	return totals, nil
}

func withDefaults(config Config) Config {
	if config.Emisar == "" {
		config.Emisar = "/opt/emisar/bin/emisar"
	}
	if config.PacksDir == "" {
		config.PacksDir = "/packs"
	}
	if config.Config == "" {
		config.Config = "/workspace/test-packs/test-config.yaml"
	}
	if config.Reports == "" {
		config.Reports = "/reports"
	}
	if config.Out == nil {
		config.Out = os.Stdout
	}
	if config.BaseEnv == nil {
		config.BaseEnv = os.Environ()
	}
	return config
}

func loadPlan(path string) (Plan, error) {
	file, err := os.Open(path)
	if err != nil {
		return Plan{}, err
	}
	defer file.Close()
	decoder := yaml.NewDecoder(file)
	decoder.KnownFields(true)
	var plan Plan
	if err := decoder.Decode(&plan); err != nil {
		return Plan{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return plan, nil
}

func loadActions(packDir string) (map[string]actionDefinition, error) {
	paths, err := filepath.Glob(filepath.Join(packDir, "actions", "*.yaml"))
	if err != nil {
		return nil, err
	}
	actions := make(map[string]actionDefinition, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var action actionDefinition
		if err := yaml.Unmarshal(data, &action); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
		if action.ID == "" {
			return nil, fmt.Errorf("%s has no action id", path)
		}
		actions[action.ID] = action
	}
	return actions, nil
}

func validatePlan(pack string, plan Plan, actions map[string]actionDefinition) error {
	if len(plan.Services) == 0 {
		return fmt.Errorf("services must name at least one disposable Compose service")
	}
	if len(plan.Cases) == 0 {
		return fmt.Errorf("cases must contain at least one behavioral case")
	}
	seen := make(map[string]bool, len(plan.Cases))
	for i, test := range plan.Cases {
		location := fmt.Sprintf("cases[%d]", i)
		action, ok := actions[test.Action]
		if !ok {
			return fmt.Errorf("%s action %q does not exist in pack %s", location, test.Action, pack)
		}
		if seen[test.Action] {
			return fmt.Errorf("%s duplicates action %q", location, test.Action)
		}
		seen[test.Action] = true
		expect := mergeExpectation(plan.Defaults.Expect, test.Expect)
		if !expect.semantic() && len(test.Probes) == 0 {
			return fmt.Errorf("%s action %q has only an exit-code assertion", location, test.Action)
		}
		for j, probe := range test.Probes {
			if err := validateStep(probe, true); err != nil {
				return fmt.Errorf("%s probes[%d]: %w", location, j, err)
			}
		}
		for j, step := range append(append([]Step{}, test.Arrange...), test.Cleanup...) {
			if err := validateStep(step, false); err != nil {
				return fmt.Errorf("%s setup/cleanup[%d]: %w", location, j, err)
			}
		}
		if action.Risk != "" && action.Risk != "low" {
			if len(test.Probes) == 0 {
				return fmt.Errorf("%s mutating action %q needs an observable state probe", location, test.Action)
			}
			if len(test.Cleanup) == 0 {
				return fmt.Errorf("%s mutating action %q needs cleanup", location, test.Action)
			}
		}
	}
	return nil
}

func validateStep(step Step, semantic bool) error {
	if len(step.Argv) == 0 || strings.TrimSpace(step.Argv[0]) == "" {
		return fmt.Errorf("argv must name an executable")
	}
	if semantic && !step.Expect.semantic() {
		return fmt.Errorf("probe needs a semantic output assertion")
	}
	if _, _, err := retryDurations(step); err != nil {
		return err
	}
	return nil
}

func (expect Expectation) semantic() bool {
	return expect.StdoutNotEmpty || len(expect.StdoutContains) > 0 || len(expect.StderrContains) > 0
}

func mergeExpectation(defaults, override Expectation) Expectation {
	merged := override
	if len(merged.Exit) == 0 {
		merged.Exit = defaults.Exit
	}
	if len(merged.Exit) == 0 {
		merged.Exit = []int{0}
	}
	merged.StdoutNotEmpty = merged.StdoutNotEmpty || defaults.StdoutNotEmpty
	if len(defaults.StdoutContains) > 0 {
		merged.StdoutContains = append(append([]string{}, defaults.StdoutContains...), merged.StdoutContains...)
	}
	if len(defaults.StderrContains) > 0 {
		merged.StderrContains = append(append([]string{}, defaults.StderrContains...), merged.StderrContains...)
	}
	return merged
}

func runPack(config Config, ref PlanRef, output io.Writer) (Totals, error) {
	plan, err := loadPlan(ref.Path)
	if err != nil {
		return Totals{}, err
	}
	packDir := filepath.Dir(filepath.Dir(ref.Path))
	actions, err := loadActions(packDir)
	if err != nil {
		return Totals{}, err
	}
	if err := validatePlan(ref.Name, plan, actions); err != nil {
		return Totals{}, err
	}
	env := environment(config.BaseEnv, plan.Env)
	totals := Totals{Actions: len(actions), Behavior: len(plan.Cases), Contract: len(actions) - len(plan.Cases)}
	for _, test := range plan.Cases {
		if err := runCase(config, plan, test, env); err != nil {
			fmt.Fprintf(output, "FAIL %s\n%s\n", test.Action, indent(err.Error()))
			totals.Fail++
			continue
		}
		fmt.Fprintf(output, "PASS %s\n", test.Action)
		totals.Pass++
	}
	fmt.Fprintf(output, "\n[%s] behavior=%d pass=%d fail=%d contract-only=%d total-actions=%d\n",
		ref.Name, totals.Behavior, totals.Pass, totals.Fail, totals.Contract, totals.Actions)
	if totals.Fail != 0 {
		return totals, fmt.Errorf("%s failed", ref.Name)
	}
	return totals, nil
}

func runCase(config Config, plan Plan, test Case, env []string) error {
	var failures []string
	for i, step := range test.Arrange {
		if err := runStep(step, env, false); err != nil {
			failures = append(failures, fmt.Sprintf("arrange[%d]: %v", i, err))
			break
		}
	}
	if len(failures) == 0 {
		args := []string{"--config", config.Config, "action", "run", test.Action}
		keys := make([]string, 0, len(test.Args))
		for key := range test.Args {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			value, err := argumentValue(test.Args[key])
			if err != nil {
				failures = append(failures, fmt.Sprintf("argument %s: %v", key, err))
				break
			}
			args = append(args, "--arg", key+"="+value)
		}
		if len(failures) == 0 {
			reason := test.Reason
			if reason == "" {
				reason = "pack behavior test"
			}
			args = append(args, "--reason", reason, "--stream")
			result, err := execute(append([]string{config.Emisar}, args...), env)
			if err == nil {
				err = checkResult(result, mergeExpectation(plan.Defaults.Expect, test.Expect))
			}
			if err != nil {
				failures = append(failures, "action: "+err.Error())
			}
		}
	}
	if len(failures) == 0 {
		for i, probe := range test.Probes {
			if err := runStep(probe, env, true); err != nil {
				failures = append(failures, fmt.Sprintf("probe[%d]: %v", i, err))
				break
			}
		}
	}
	for i, cleanup := range test.Cleanup {
		if err := runStep(cleanup, env, false); err != nil {
			failures = append(failures, fmt.Sprintf("cleanup[%d]: %v", i, err))
		}
	}
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "\n"))
	}
	return nil
}

func runStep(step Step, baseEnv []string, requireSemantic bool) error {
	retryFor, retryEvery, err := retryDurations(step)
	if err != nil {
		return err
	}
	expect := mergeExpectation(Expectation{}, step.Expect)
	if !requireSemantic && !step.Expect.semantic() {
		expect.StdoutNotEmpty = false
	}
	env := environment(baseEnv, step.Env)
	deadline := time.Now().Add(retryFor)
	for {
		result, runErr := execute(step.Argv, env)
		if runErr == nil {
			runErr = checkResult(result, expect)
		}
		if runErr == nil {
			return nil
		}
		if retryFor == 0 || !time.Now().Before(deadline) {
			if step.Name != "" {
				return fmt.Errorf("%s: %w", step.Name, runErr)
			}
			return runErr
		}
		sleepFor := min(retryEvery, time.Until(deadline))
		time.Sleep(sleepFor)
	}
}

func retryDurations(step Step) (time.Duration, time.Duration, error) {
	if step.RetryFor == "" {
		if step.RetryEvery != "" {
			return 0, 0, fmt.Errorf("retry_every requires retry_for")
		}
		return 0, 0, nil
	}
	retryFor, err := time.ParseDuration(step.RetryFor)
	if err != nil || retryFor <= 0 {
		return 0, 0, fmt.Errorf("invalid retry_for %q", step.RetryFor)
	}
	retryEvery := time.Second
	if step.RetryEvery != "" {
		retryEvery, err = time.ParseDuration(step.RetryEvery)
		if err != nil || retryEvery <= 0 {
			return 0, 0, fmt.Errorf("invalid retry_every %q", step.RetryEvery)
		}
	}
	return retryFor, retryEvery, nil
}

func execute(argv, env []string) (commandResult, error) {
	if len(argv) == 0 {
		return commandResult{}, fmt.Errorf("empty argv")
	}
	command := exec.Command(argv[0], argv[1:]...)
	command.Env = env
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			return commandResult{}, err
		}
		exitCode = exitErr.ExitCode()
	}
	return commandResult{exitCode: exitCode, stdout: stdout.String(), stderr: stderr.String()}, nil
}

func checkResult(result commandResult, expect Expectation) error {
	if !accepts(expect.Exit, result.exitCode) {
		return fmt.Errorf("exit=%d, expected=%v\nstdout:\n%s\nstderr:\n%s",
			result.exitCode, expect.Exit, result.stdout, result.stderr)
	}
	if expect.StdoutNotEmpty && strings.TrimSpace(result.stdout) == "" {
		return fmt.Errorf("stdout is empty")
	}
	for _, needle := range expect.StdoutContains {
		if !strings.Contains(result.stdout, needle) {
			return fmt.Errorf("stdout does not contain %q\nstdout:\n%s", needle, result.stdout)
		}
	}
	for _, needle := range expect.StderrContains {
		if !strings.Contains(result.stderr, needle) {
			return fmt.Errorf("stderr does not contain %q\nstderr:\n%s", needle, result.stderr)
		}
	}
	return nil
}

func accepts(codes []int, code int) bool {
	for _, allowed := range codes {
		if code == allowed {
			return true
		}
	}
	return false
}

func argumentValue(value any) (string, error) {
	if text, ok := value.(string); ok {
		return text, nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func environment(base []string, overrides map[string]string) []string {
	values := make(map[string]string, len(base)+len(overrides))
	for _, entry := range base {
		key, value, found := strings.Cut(entry, "=")
		if found {
			values[key] = value
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, key := range keys {
		env = append(env, key+"="+values[key])
	}
	return env
}

func indent(value string) string {
	return "  " + strings.ReplaceAll(strings.TrimSpace(value), "\n", "\n  ")
}
