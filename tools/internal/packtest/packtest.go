// Package packtest executes pack-owned behavioral plans against disposable
// Compose services. Pack validation covers every action contract; this package
// counts only cases that exercise observable behavior as integration coverage.
package packtest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

var commandTimeout = 30 * time.Second

type Expectation struct {
	Status            string         `yaml:"status,omitempty"`
	Exit              []int          `yaml:"exit,omitempty"`
	ReasonContains    []string       `yaml:"reason_contains,omitempty"`
	StdoutNotEmpty    bool           `yaml:"stdout_not_empty,omitempty"`
	StdoutContains    []string       `yaml:"stdout_contains,omitempty"`
	StdoutNotContains []string       `yaml:"stdout_not_contains,omitempty"`
	StderrContains    []string       `yaml:"stderr_contains,omitempty"`
	StderrNotContains []string       `yaml:"stderr_not_contains,omitempty"`
	JSON              map[string]any `yaml:"json,omitempty"`
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
	Name         string            `yaml:"name,omitempty"`
	Action       string            `yaml:"action"`
	RunnerUser   string            `yaml:"runner_user,omitempty"`
	RunnerReason string            `yaml:"runner_reason,omitempty"`
	Env          map[string]string `yaml:"env,omitempty"`
	UnsetEnv     []string          `yaml:"unset_env,omitempty"`
	Args         map[string]any    `yaml:"args,omitempty"`
	ResolveArgs  map[string]Step   `yaml:"resolve_args,omitempty"`
	Reason       string            `yaml:"reason,omitempty"`
	Expect       Expectation       `yaml:"expect,omitempty"`
	Arrange      []Step            `yaml:"arrange,omitempty"`
	Probes       []Step            `yaml:"probes,omitempty"`
	Cleanup      []Step            `yaml:"cleanup,omitempty"`
}

type Defaults struct {
	Expect Expectation `yaml:"expect,omitempty"`
}

type Version struct {
	Version string `yaml:"version"`
	Digest  string `yaml:"digest"`
	Default bool   `yaml:"default,omitempty"`
}

type Runner struct {
	User   string `yaml:"user,omitempty"`
	Reason string `yaml:"reason,omitempty"`
}

type Plan struct {
	Services  []string          `yaml:"services"`
	Versions  []Version         `yaml:"versions"`
	Runner    Runner            `yaml:"runner,omitempty"`
	SecretEnv []string          `yaml:"secret_env,omitempty"`
	Env       map[string]string `yaml:"env,omitempty"`
	Defaults  Defaults          `yaml:"defaults,omitempty"`
	Shards    int               `yaml:"shards,omitempty"`
	Workers   int               `yaml:"workers,omitempty"`
	Cases     []Case            `yaml:"cases"`
}

type CaseRef struct {
	ID         string
	Action     string
	RunnerUser string
}

type PlanRef struct {
	Name        string
	PackVersion string
	Path        string
	Services    []string
	Versions    []Version
	Runner      Runner
	Shards      int
	Workers     int
	Cases       []CaseRef
}

type MatrixRow struct {
	Pack    string `json:"pack"`
	Version string `json:"version"`
	Digest  string `json:"digest"`
	Shard   int    `json:"shard"`
	Shards  int    `json:"shards"`
}

type Config struct {
	Emisar   string
	PacksDir string
	Config   string
	Reports  string
	Pattern  string
	Names    []string
	Case     string
	Out      io.Writer
	BaseEnv  []string

	// Read out of the harness config at startup rather than restated here: the
	// secret-canary check used to name /tmp/emisar-test/events.jsonl literally,
	// so renaming the key in test-config.yaml would have failed every case in
	// 45 of 84 packs with a read error that named a path nothing wrote.
	eventsPath string
}

type Totals struct {
	Pass, Fail                  int
	PacksRun, PacksFailed       int
	Actions, Behavior, Contract int
}

func (totals Totals) Failed() bool { return totals.Fail != 0 || totals.PacksFailed != 0 }

type actionArgument struct {
	Name string `yaml:"name"`
	Type string `yaml:"type"`
}

type actionDefinition struct {
	ID          string           `yaml:"id"`
	Risk        string           `yaml:"risk"`
	SideEffects []string         `yaml:"side_effects"`
	Args        []actionArgument `yaml:"args"`
	Output      struct {
		Parser string `yaml:"parser"`
	} `yaml:"output"`
}

type commandResult struct {
	exitCode int
	stdout   string
	stderr   string
}

type actionResult struct {
	Status      string `json:"status"`
	ExitCode    int    `json:"exit_code"`
	Stdout      string `json:"stdout"`
	Stderr      string `json:"stderr"`
	Reason      string `json:"reason"`
	Error       string `json:"error"`
	DurationMS  int64  `json:"duration_ms"`
	ParserError string `json:"parser_error"`
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
		if err := validateVersions(plan.Versions); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		packVersion, err := loadPackVersion(filepath.Dir(filepath.Dir(path)))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		cases := make([]CaseRef, 0, len(plan.Cases))
		for _, test := range plan.Cases {
			cases = append(cases, CaseRef{
				ID:         test.ID(),
				Action:     test.Action,
				RunnerUser: effectiveRunnerUser(plan.Runner.User, test.RunnerUser),
			})
		}
		plans = append(plans, PlanRef{
			Name: name, PackVersion: packVersion, Path: path, Services: plan.Services,
			Versions: plan.Versions, Runner: plan.Runner, Shards: plan.Shards, Workers: plan.Workers, Cases: cases,
		})
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

func loadPackVersion(packDir string) (string, error) {
	data, err := os.ReadFile(filepath.Join(packDir, "pack.yaml"))
	if errors.Is(err, os.ErrNotExist) {
		return "unknown", nil
	}
	if err != nil {
		return "", err
	}
	var manifest struct {
		Version string `yaml:"version"`
	}
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		return "", err
	}
	if strings.TrimSpace(manifest.Version) == "" {
		return "", fmt.Errorf("pack.yaml has no version")
	}
	return manifest.Version, nil
}

// packTestMaxWorkers caps how many cases run at once. A plan may ask for fewer
// when one SUT is heavy enough that four of them starve each other.
const packTestMaxWorkers = 4

// Workers reports how many of a selection's cases may run at once, which is the
// smallest any selected plan is willing to tolerate.
func Workers(plans []PlanRef) int {
	workers := packTestMaxWorkers
	for _, plan := range plans {
		if plan.Workers > 0 && plan.Workers < workers {
			workers = plan.Workers
		}
	}
	return workers
}

func Matrix(plans []PlanRef) []MatrixRow {
	// Non-nil so an empty matrix marshals to `[]`, never `null`: the CI
	// change-selection output feeds `= '[]'` guards, and a `null` there makes
	// the behavior job run on an empty matrix and the required-checks gate
	// demand a job that had nothing to run — which blocked every deploy whose
	// push touched no packs.
	rows := []MatrixRow{}
	for _, plan := range plans {
		shards := max(plan.Shards, 1)
		for _, version := range plan.Versions {
			for shard := 1; shard <= shards; shard++ {
				rows = append(rows, MatrixRow{
					Pack: plan.Name, Version: version.Version, Digest: version.Digest,
					Shard: shard, Shards: shards,
				})
			}
		}
	}
	return rows
}

// SelectShard keeps the cases belonging to one shard. Every case in a plan
// boots the same SUT, so cost tracks count and dealing round-robin balances
// the shards without any estimate of how long a case takes.
func SelectShard(cases []CaseRef, shard, shards int) []CaseRef {
	if shards <= 1 {
		return cases
	}
	selected := make([]CaseRef, 0, len(cases)/shards+1)
	for i, test := range cases {
		if i%shards == shard-1 {
			selected = append(selected, test)
		}
	}
	return selected
}

func Validate(plans []PlanRef) error {
	for _, ref := range plans {
		plan, err := loadPlan(ref.Path)
		if err != nil {
			return err
		}
		actions, err := loadActions(filepath.Dir(filepath.Dir(ref.Path)))
		if err != nil {
			return err
		}
		if err := validatePlan(ref.Name, plan, actions); err != nil {
			return fmt.Errorf("%s: %w", ref.Name, err)
		}
		composePath := filepath.Join(filepath.Dir(ref.Path), "compose.yaml")
		compose, err := os.ReadFile(composePath)
		if err != nil {
			return fmt.Errorf("%s: read compose.yaml: %w", ref.Name, err)
		}
		if err := validateFixturePlan(ref.Name, plan, compose); err != nil {
			return fmt.Errorf("%s: %w", ref.Name, err)
		}
	}
	return nil
}

func (ref PlanRef) DefaultVersion() Version {
	for _, version := range ref.Versions {
		if version.Default {
			return version
		}
	}
	return Version{}
}

func (test Case) ID() string {
	if test.Name != "" {
		return test.Name
	}
	return test.Action
}

func effectiveRunnerUser(planUser, caseUser string) string {
	if caseUser != "" {
		return caseUser
	}
	if planUser != "" {
		return planUser
	}
	return "nonroot"
}

func Run(config Config) (Totals, error) {
	config = withDefaults(config)
	if info, err := os.Stat(config.Emisar); err != nil || info.Mode()&0o111 == 0 {
		return Totals{}, fmt.Errorf("emisar binary not found or executable at %s", config.Emisar)
	}
	staged, err := stageConfig(config.Config)
	if err != nil {
		return Totals{}, err
	}
	// The staged copy is a 0600 runner config in a private temp directory. Only
	// the test cleaned it up, so every real invocation left one behind.
	defer os.RemoveAll(filepath.Dir(staged))
	config.Config = staged
	config.eventsPath, err = eventsPathFrom(config.Config)
	if err != nil {
		return Totals{}, err
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

// stageConfig copies the harness config somewhere this process owns and no one
// else can write, and returns that path.
//
// The runner refuses a config owned by neither root nor itself, and one that is
// group- or world-writable, because whoever holds that write bit chooses the
// packs it loads. That check is the product working. But the harness reads its
// config from /workspace, a read-only bind mount of the host config file, which
// carries the HOST's ownership: on CI that is the job user, so the runner
// correctly refused every action and all 42 behavior packs failed at once.
// Docker Desktop remaps bind-mount ownership to the container user, so a
// workstation never sees it — the Linux matrix is the only judge of this class.
//
// Copying rather than relaxing the check keeps the harness exercising the real
// admission path, and works for a root and a nonroot runner_user alike, since
// the copy is owned by whoever is running.
func stageConfig(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read harness config %s: %w", path, err)
	}
	// A private 0700 directory rather than a fixed name in the shared /tmp, so
	// nothing else can pre-create the path we are about to write.
	dir, err := os.MkdirTemp("", "packtest-config")
	if err != nil {
		return "", fmt.Errorf("stage harness config: %w", err)
	}
	staged := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(staged, contents, 0o600); err != nil {
		return "", fmt.Errorf("stage harness config at %s: %w", staged, err)
	}
	return staged, nil
}

// eventsPathFrom reads the audit journal path out of the harness config, which
// is the file that decides it. A missing key is an error, not a fallback: the
// secret-canary check proves a secret never reached the journal, and a check
// that reads nothing passes for the wrong reason.
func eventsPathFrom(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read harness config %s: %w", path, err)
	}
	var config struct {
		Events struct {
			JSONLPath string `yaml:"jsonl_path"`
		} `yaml:"events"`
	}
	if err := yaml.Unmarshal(data, &config); err != nil {
		return "", fmt.Errorf("parse harness config %s: %w", path, err)
	}
	if config.Events.JSONLPath == "" {
		return "", fmt.Errorf("harness config %s sets no events.jsonl_path for the secret-canary check", path)
	}
	return config.Events.JSONLPath, nil
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
	if err := validateVersions(plan.Versions); err != nil {
		return err
	}
	if err := validateRunner(plan.Runner); err != nil {
		return err
	}
	if err := validateSecretEnv(plan.SecretEnv, plan.Env); err != nil {
		return err
	}
	if len(plan.Services) == 0 {
		return fmt.Errorf("services must name at least one disposable Compose service")
	}
	if len(plan.Cases) == 0 {
		return fmt.Errorf("cases must contain at least one behavioral case")
	}
	if plan.Shards < 0 || plan.Shards > len(plan.Cases) {
		return fmt.Errorf("shards must be between 1 and the %d declared cases", len(plan.Cases))
	}
	if plan.Workers < 0 || plan.Workers > packTestMaxWorkers {
		return fmt.Errorf("workers must be between 1 and %d", packTestMaxWorkers)
	}
	seen := make(map[string]bool, len(plan.Cases))
	for i, test := range plan.Cases {
		location := fmt.Sprintf("cases[%d]", i)
		action, ok := actions[test.Action]
		if !ok {
			return fmt.Errorf("%s action %q does not exist in pack %s", location, test.Action, pack)
		}
		id := test.ID()
		if !caseIDPattern.MatchString(id) {
			return fmt.Errorf("%s has invalid case name %q", location, id)
		}
		if seen[id] {
			return fmt.Errorf("%s duplicates case %q", location, id)
		}
		seen[id] = true
		if err := validateRunnerUser(test.RunnerUser); err != nil {
			return fmt.Errorf("%s: %w", location, err)
		}
		if test.RunnerUser == "root" && strings.TrimSpace(test.RunnerReason) == "" {
			return fmt.Errorf("%s runner_user root requires runner_reason", location)
		}
		if test.RunnerUser != "root" && strings.TrimSpace(test.RunnerReason) != "" {
			return fmt.Errorf("%s runner_reason is only valid for runner_user root", location)
		}
		if err := validateCaseSecretEnv(plan.SecretEnv, plan.Env, test.Env, test.UnsetEnv); err != nil {
			return fmt.Errorf("%s: %w", location, err)
		}
		expect := mergeActionExpectation(plan.Defaults.Expect, test.Expect)
		if err := validateActionExpectation(expect); err != nil {
			return fmt.Errorf("%s expect: %w", location, err)
		}
		if !expect.semantic() && len(test.Probes) == 0 {
			return fmt.Errorf("%s action %q has no semantic assertion", location, test.Action)
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
		for name, resolver := range test.ResolveArgs {
			if _, exists := test.Args[name]; exists {
				return fmt.Errorf("%s resolve_args.%s duplicates a static argument", location, name)
			}
			argumentType := action.argumentType(name)
			if argumentType == "" {
				return fmt.Errorf("%s resolve_args.%s does not name an action argument", location, name)
			}
			// resolveArgument reads one line of stdout, so it can only produce an
			// integer or a string. Checking existence alone let a path, boolean,
			// object, array, regex, duration, or number argument pass authoring
			// and fail at "argument type %q cannot be resolved dynamically" —
			// after the SUT had booted and the case was already running.
			if !resolvableArgumentTypes[argumentType] {
				return fmt.Errorf("%s resolve_args.%s is a %s argument; only %s can be resolved from a command",
					location, name, argumentType, strings.Join(sortedResolvableTypes(), " and "))
			}
			if !reflect.DeepEqual(resolver.Expect, Expectation{}) {
				return fmt.Errorf("%s resolve_args.%s cannot declare expect", location, name)
			}
			if err := validateStep(resolver, false); err != nil {
				return fmt.Errorf("%s resolve_args.%s: %w", location, name, err)
			}
		}
		if action.mutates() && expect.Status == "success" {
			if len(test.Probes) == 0 {
				return fmt.Errorf("%s mutating action %q needs an observable state probe", location, test.Action)
			}
		}
		if expect.Status == "success" && actionNeedsArrangedState(test.Action) && len(test.Arrange) == 0 {
			return fmt.Errorf("%s cumulative action %q needs arrange state in its isolated case", location, test.Action)
		}
	}
	return nil
}

func actionNeedsArrangedState(action string) bool {
	leaf := action
	if index := strings.LastIndexByte(leaf, '.'); index >= 0 {
		leaf = leaf[index+1:]
	}
	if leaf == "top" || strings.HasPrefix(leaf, "top_") || strings.Contains(leaf, "_top_") || strings.HasSuffix(leaf, "_top") {
		return true
	}
	switch leaf {
	case "get_metric_statistics", "runtime_metrics", "statement_stats", "stats_sizes":
		return true
	default:
		return false
	}
}

type fixtureCompose struct {
	Services map[string]fixtureService `yaml:"services"`
}

type fixtureService struct {
	Image       string             `yaml:"image"`
	Volumes     []string           `yaml:"volumes"`
	Healthcheck fixtureHealthcheck `yaml:"healthcheck"`
}

type fixtureHealthcheck struct {
	Test          []string `yaml:"test"`
	Interval      string   `yaml:"interval"`
	StartInterval string   `yaml:"start_interval"`
}

func validateFixturePlan(pack string, plan Plan, data []byte) error {
	var compose fixtureCompose
	if err := yaml.Unmarshal(data, &compose); err != nil {
		return fmt.Errorf("parse compose.yaml: %w", err)
	}
	primaryName := plan.Services[0]
	primary, exists := compose.Services[primaryName]
	if !exists {
		return fmt.Errorf("primary SUT service %q is missing from compose.yaml", primaryName)
	}
	command := strings.ToLower(strings.Join(primary.Healthcheck.Test, " "))
	if seedsThroughEntrypoint(primary.Volumes) && usesLoopback(command) && !strings.Contains(command, "hostname -i") {
		return fmt.Errorf("primary SUT healthcheck dials loopback while docker-entrypoint-initdb.d can expose its temporary seed daemon; dial hostname -i")
	}
	if pack == "zookeeper" && usesLoopback(command) {
		return fmt.Errorf("zookeeper healthcheck must dial hostname -i, the same bridge address its cases use")
	}
	if primary.Healthcheck.StartInterval != "" && heavyweightHealthcheck(command) {
		interval, err := time.ParseDuration(primary.Healthcheck.StartInterval)
		if err != nil {
			return fmt.Errorf("primary SUT healthcheck has invalid start_interval %q", primary.Healthcheck.StartInterval)
		}
		if strings.Contains(command, "rabbitmq") || strings.Contains(command, "erl ") {
			return fmt.Errorf("RabbitMQ/Erlang healthcheck must not use start_interval before the entrypoint owns its cookie")
		}
		if interval < 5*time.Second {
			return fmt.Errorf("heavyweight primary SUT healthcheck start_interval %s is below 5s", primary.Healthcheck.StartInterval)
		}
	}
	for index, test := range plan.Cases {
		if !strings.Contains(strings.ToLower(test.Action), "getendpoints") {
			continue
		}
		for _, value := range test.Expect.StdoutContains {
			for _, address := range ipv4Pattern.FindAllString(value, -1) {
				if !bytes.Contains(data, []byte(address)) {
					return fmt.Errorf("cases[%d] action %q expects environment-assigned address %s without pinning it in compose.yaml", index, test.Action, address)
				}
			}
		}
	}
	return nil
}

func seedsThroughEntrypoint(volumes []string) bool {
	for _, volume := range volumes {
		if strings.Contains(volume, "/docker-entrypoint-initdb.d/") {
			return true
		}
	}
	return false
}

func usesLoopback(command string) bool {
	return strings.Contains(command, "127.0.0.1") || strings.Contains(command, "localhost")
}

func heavyweightHealthcheck(command string) bool {
	for _, marker := range []string{
		"cqlsh", "kafka-", "kubectl", "mongo", "mysql ", "nodetool", "rabbitmq", " zookeeper", "java ", "erl ",
	} {
		if strings.Contains(command, marker) {
			return true
		}
	}
	return false
}

var (
	versionPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)
	digestPattern  = regexp.MustCompile(`^@sha256:[a-f0-9]{64}$`)
	caseIDPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,127}$`)
	canaryPattern  = regexp.MustCompile(`packtest-canary-[A-Za-z0-9._-]+`)
	ipv4Pattern    = regexp.MustCompile(`(?:[0-9]{1,3}\.){3}[0-9]{1,3}`)
)

// ValidDigest reports whether an image digest is the pinned
// @sha256:<64 lowercase hex characters> form every SUT version must carry.
func ValidDigest(digest string) bool {
	return digestPattern.MatchString(digest)
}

func validateRunner(runner Runner) error {
	if err := validateRunnerUser(runner.User); err != nil {
		return err
	}
	if runner.User == "root" && strings.TrimSpace(runner.Reason) == "" {
		return fmt.Errorf("runner.user root requires a reason")
	}
	if runner.User != "root" && strings.TrimSpace(runner.Reason) != "" {
		return fmt.Errorf("runner.reason is only valid for runner.user root")
	}
	return nil
}

func validateRunnerUser(user string) error {
	if user != "" && user != "nonroot" && user != "root" {
		return fmt.Errorf("runner user %q must be nonroot or root", user)
	}
	return nil
}

func validateSecretEnv(keys []string, env map[string]string) error {
	seenValues := make(map[string]string, len(keys))
	for i, key := range keys {
		value, ok := env[key]
		if !ok || value == "" {
			return fmt.Errorf("secret_env[%d] %q has no non-empty env value", i, key)
		}
		canaries := canaryPattern.FindAllString(value, -1)
		if len(canaries) == 0 {
			return fmt.Errorf("secret_env[%d] %q must contain a packtest-canary- value", i, key)
		}
		for _, canary := range canaries {
			if previous, exists := seenValues[canary]; exists {
				return fmt.Errorf("secret_env %q and %q reuse canary %q", previous, key, canary)
			}
			seenValues[canary] = key
		}
	}
	return nil
}

func validateCaseSecretEnv(keys []string, base, overrides map[string]string, unsetKeys []string) error {
	values := make(map[string]string, len(base)+len(overrides))
	for key, value := range base {
		values[key] = value
	}
	for key, value := range overrides {
		values[key] = value
	}
	unset := make(map[string]bool, len(unsetKeys))
	for _, key := range unsetKeys {
		unset[key] = true
		delete(values, key)
	}
	active := make([]string, 0, len(keys))
	for _, key := range keys {
		if !unset[key] {
			active = append(active, key)
		}
	}
	return validateSecretEnv(active, values)
}

func validateVersions(versions []Version) error {
	if len(versions) == 0 {
		return fmt.Errorf("versions must declare at least one supported SUT image")
	}
	defaults := 0
	seen := make(map[string]bool, len(versions))
	for i, version := range versions {
		location := fmt.Sprintf("versions[%d]", i)
		if !versionPattern.MatchString(version.Version) {
			return fmt.Errorf("%s has invalid image tag %q", location, version.Version)
		}
		if !ValidDigest(version.Digest) {
			return fmt.Errorf("%s digest must match @sha256:<64 lowercase hex characters>", location)
		}
		if seen[version.Version] {
			return fmt.Errorf("%s duplicates version %q", location, version.Version)
		}
		seen[version.Version] = true
		if version.Default {
			defaults++
		}
	}
	if defaults != 1 {
		return fmt.Errorf("versions must mark exactly one default, got %d", defaults)
	}
	return nil
}

func (action actionDefinition) mutates() bool {
	for _, effect := range action.SideEffects {
		if strings.Contains(strings.ToLower(effect), "read-only") {
			return false
		}
	}
	return action.Risk != "" && action.Risk != "low"
}

func (action actionDefinition) argumentType(name string) string {
	for _, argument := range action.Args {
		if argument.Name == name {
			return argument.Type
		}
	}
	return ""
}

func validateStep(step Step, semantic bool) error {
	if len(step.Argv) == 0 || strings.TrimSpace(step.Argv[0]) == "" {
		return fmt.Errorf("argv must name an executable")
	}
	if semantic && !step.Expect.semantic() {
		return fmt.Errorf("probe needs a semantic output assertion")
	}
	if step.Expect.Status != "" || len(step.Expect.ReasonContains) > 0 {
		return fmt.Errorf("direct command steps cannot assert action status or reason")
	}
	if err := validateJSONPointers(step.Expect.JSON); err != nil {
		return err
	}
	if _, _, err := retryDurations(step); err != nil {
		return err
	}
	return nil
}

func (expect Expectation) semantic() bool {
	return len(expect.ReasonContains) > 0 || len(expect.StdoutContains) > 0 ||
		len(expect.StderrContains) > 0 || len(expect.JSON) > 0
}

func validateActionExpectation(expect Expectation) error {
	if expect.Status != "success" && expect.Status != "failure" {
		return fmt.Errorf("status %q must be success or failure", expect.Status)
	}
	if expect.Status == "success" && len(expect.ReasonContains) > 0 {
		return fmt.Errorf("reason_contains requires failure status")
	}
	return validateJSONPointers(expect.JSON)
}

func mergeActionExpectation(defaults, override Expectation) Expectation {
	merged := override
	if merged.Status == "" {
		merged.Status = defaults.Status
	}
	if merged.Status == "" {
		merged.Status = "success"
	}
	if len(merged.Exit) == 0 {
		merged.Exit = defaults.Exit
	}
	if len(merged.Exit) == 0 && merged.Status == "success" {
		merged.Exit = []int{0}
	}
	if merged.Status == "success" {
		merged.StdoutNotEmpty = merged.StdoutNotEmpty || defaults.StdoutNotEmpty
	}
	merged.ReasonContains = mergeStrings(defaults.ReasonContains, merged.ReasonContains)
	merged.StdoutContains = mergeStrings(defaults.StdoutContains, merged.StdoutContains)
	merged.StdoutNotContains = mergeStrings(defaults.StdoutNotContains, merged.StdoutNotContains)
	merged.StderrContains = mergeStrings(defaults.StderrContains, merged.StderrContains)
	merged.StderrNotContains = mergeStrings(defaults.StderrNotContains, merged.StderrNotContains)
	if len(defaults.JSON) > 0 {
		if merged.JSON == nil {
			merged.JSON = make(map[string]any, len(defaults.JSON))
		}
		for pointer, value := range defaults.JSON {
			if _, overridden := merged.JSON[pointer]; !overridden {
				merged.JSON[pointer] = value
			}
		}
	}
	return merged
}

func mergeStepExpectation(expect Expectation) Expectation {
	merged := expect
	if len(merged.Exit) == 0 {
		merged.Exit = []int{0}
	}
	return merged
}

func mergeStrings(defaults, overrides []string) []string {
	if len(defaults) > 0 {
		return append(append([]string{}, defaults...), overrides...)
	}
	return overrides
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
	tests := plan.Cases
	if config.Case != "" {
		tests = nil
		for _, test := range plan.Cases {
			if test.ID() == config.Case {
				tests = append(tests, test)
				break
			}
		}
		if len(tests) == 0 {
			return Totals{}, fmt.Errorf("pack %s has no case %q", ref.Name, config.Case)
		}
	}
	env := environment(config.BaseEnv, plan.Env)
	covered := make(map[string]bool, len(plan.Cases))
	for _, test := range plan.Cases {
		covered[test.Action] = true
	}
	totals := Totals{Actions: len(actions), Behavior: len(covered), Contract: len(actions) - len(covered)}
	for _, test := range tests {
		started := time.Now()
		if err := runCase(config, plan, test, actions[test.Action], env); err != nil {
			fmt.Fprintf(output, "FAIL %s duration=%s\n%s\n",
				test.ID(), time.Since(started).Round(time.Millisecond), indent(err.Error()))
			totals.Fail++
			continue
		}
		fmt.Fprintf(output, "PASS %s duration=%s\n", test.ID(), time.Since(started).Round(time.Millisecond))
		totals.Pass++
	}
	fmt.Fprintf(output, "\n[%s] behavior=%d pass=%d fail=%d contract-only=%d total-actions=%d\n",
		ref.Name, totals.Behavior, totals.Pass, totals.Fail, totals.Contract, totals.Actions)
	if totals.Fail != 0 {
		return totals, fmt.Errorf("%s failed", ref.Name)
	}
	return totals, nil
}

func runCase(config Config, plan Plan, test Case, action actionDefinition, env []string) error {
	env = environment(env, test.Env)
	env = withoutEnvironment(env, test.UnsetEnv)
	var failures []string
	var actionEvidence *actionResult
	for i, step := range test.Arrange {
		if err := runStep(step, env, false); err != nil {
			failures = append(failures, fmt.Sprintf("arrange[%d]: %v", i, err))
			break
		}
	}
	if len(failures) == 0 {
		arguments := make(map[string]any, len(test.Args)+len(test.ResolveArgs))
		for key, value := range test.Args {
			arguments[key] = value
		}
		resolvedKeys := make([]string, 0, len(test.ResolveArgs))
		for key := range test.ResolveArgs {
			resolvedKeys = append(resolvedKeys, key)
		}
		sort.Strings(resolvedKeys)
		for _, key := range resolvedKeys {
			value, err := resolveArgument(test.ResolveArgs[key], env, action.argumentType(key))
			if err != nil {
				failures = append(failures, fmt.Sprintf("resolve argument %s: %v", key, err))
				break
			}
			arguments[key] = value
		}
		args := []string{"--config", config.Config, "action", "run", test.Action}
		keys := make([]string, 0, len(arguments))
		for key := range arguments {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			value, err := argumentValue(arguments[key])
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
			args = append(args, "--reason", reason)
			result, err := executeAction(append([]string{config.Emisar}, args...), env)
			if err == nil {
				actionEvidence = &result
				resultErr := checkActionResult(
					result,
					mergeActionExpectation(plan.Defaults.Expect, test.Expect),
					action.Output.Parser == "json",
				)
				secretErr := checkSecretCanaries(
					plan.SecretEnv,
					environmentMap(env),
					result,
					config.eventsPath,
				)
				err = errors.Join(resultErr, secretErr)
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
		if actionEvidence != nil {
			encoded, err := json.MarshalIndent(actionEvidence, "", "  ")
			if err == nil {
				failures = append(failures, "action result:\n"+string(encoded))
			}
		}
		return errors.New(strings.Join(failures, "\n"))
	}
	return nil
}

// The argument types resolveArgument can produce from one line of stdout. The
// authoring check reads this set, so adding a case below without adding it here
// keeps failing at run time — and removing one starts failing at authoring time,
// which is where the pack author is.
var resolvableArgumentTypes = map[string]bool{"integer": true, "string": true}

func sortedResolvableTypes() []string {
	types := make([]string, 0, len(resolvableArgumentTypes))
	for name := range resolvableArgumentTypes {
		types = append(types, name)
	}
	sort.Strings(types)
	return types
}

func resolveArgument(step Step, baseEnv []string, argumentType string) (any, error) {
	retryFor, retryEvery, err := retryDurations(step)
	if err != nil {
		return nil, err
	}
	env := environment(baseEnv, step.Env)
	deadline := time.Now().Add(retryFor)
	for {
		result, runErr := execute(step.Argv, env)
		if runErr == nil && result.exitCode != 0 {
			runErr = fmt.Errorf("exit=%d\nstdout:\n%s\nstderr:\n%s",
				result.exitCode, result.stdout, result.stderr)
		}
		value := strings.TrimSpace(result.stdout)
		if runErr == nil && (value == "" || strings.ContainsAny(value, "\r\n")) {
			runErr = fmt.Errorf("stdout must contain exactly one non-empty line\nstdout:\n%s", result.stdout)
		}
		if runErr == nil {
			switch argumentType {
			case "integer":
				parsed, parseErr := strconv.ParseInt(value, 10, 64)
				if parseErr != nil {
					runErr = fmt.Errorf("parse integer %q: %w", value, parseErr)
				} else {
					return parsed, nil
				}
			case "string":
				return value, nil
			default:
				return nil, fmt.Errorf("argument type %q cannot be resolved dynamically", argumentType)
			}
		}
		if retryFor == 0 || !time.Now().Before(deadline) {
			if step.Name != "" {
				return nil, fmt.Errorf("%s: %w", step.Name, runErr)
			}
			return nil, runErr
		}
		time.Sleep(min(retryEvery, time.Until(deadline)))
	}
}

func executeAction(argv, env []string) (actionResult, error) {
	result, err := execute(argv, env)
	if err != nil {
		return actionResult{}, err
	}
	// `emisar action run` exits non-zero when the ACTION failed — `pack info`
	// names it the "verify it works" step, so a script has to be able to detect
	// that — but it prints the result JSON first. A case with
	// `expect: {status: failure}` is exercising exactly that path, so the exit
	// code is not the harness's verdict; the parsed result checked against the
	// case's `expect` is. A run that produced no parseable result IS a harness
	// error, and a non-zero exit tells us more about it than the decoder does.
	var action actionResult
	if decodeErr := json.Unmarshal([]byte(result.stdout), &action); decodeErr != nil {
		if result.exitCode != 0 {
			return actionResult{}, fmt.Errorf("runner exit=%d\nstdout:\n%s\nstderr:\n%s",
				result.exitCode, result.stdout, result.stderr)
		}
		return actionResult{}, fmt.Errorf("decode action result: %w\nstdout:\n%s",
			decodeErr, result.stdout)
	}
	return action, nil
}

func runStep(step Step, baseEnv []string, requireSemantic bool) error {
	retryFor, retryEvery, err := retryDurations(step)
	if err != nil {
		return err
	}
	expect := mergeStepExpectation(step.Expect)
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
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, argv[0], argv[1:]...)
	command.Env = env
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return commandResult{stdout: stdout.String(), stderr: stderr.String()},
			fmt.Errorf("command timed out after %s: %s", commandTimeout, strings.Join(argv, " "))
	}
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
	if len(expect.Exit) > 0 && !slices.Contains(expect.Exit, result.exitCode) {
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
	for _, needle := range expect.StdoutNotContains {
		if strings.Contains(result.stdout, needle) {
			return fmt.Errorf("stdout contains forbidden %q\nstdout:\n%s", needle, result.stdout)
		}
	}
	for _, needle := range expect.StderrContains {
		if !strings.Contains(result.stderr, needle) {
			return fmt.Errorf("stderr does not contain %q\nstderr:\n%s", needle, result.stderr)
		}
	}
	for _, needle := range expect.StderrNotContains {
		if strings.Contains(result.stderr, needle) {
			return fmt.Errorf("stderr contains forbidden %q\nstderr:\n%s", needle, result.stderr)
		}
	}
	if len(expect.JSON) > 0 {
		return checkJSONAssertions(result.stdout, expect.JSON)
	}
	return nil
}

func checkActionResult(result actionResult, expect Expectation, requireJSON bool) error {
	success := result.Status == "success"
	if expect.Status == "success" && !success || expect.Status == "failure" && success {
		return fmt.Errorf("action status=%s, expected=%s\nreason: %s\nerror: %s\nstdout:\n%s\nstderr:\n%s",
			result.Status, expect.Status, result.Reason, result.Error, result.Stdout, result.Stderr)
	}
	if len(expect.Exit) > 0 && !slices.Contains(expect.Exit, result.ExitCode) {
		return fmt.Errorf("action exit=%d, expected=%v\nstatus=%s\nreason=%s\nstdout:\n%s\nstderr:\n%s",
			result.ExitCode, expect.Exit, result.Status, result.Reason, result.Stdout, result.Stderr)
	}
	for _, needle := range expect.ReasonContains {
		if !strings.Contains(result.Reason, needle) {
			return fmt.Errorf("reason does not contain %q\nreason: %s", needle, result.Reason)
		}
	}
	streamExpect := expect
	streamExpect.Exit = nil
	streamExpect.ReasonContains = nil
	streamExpect.JSON = nil
	if err := checkResult(commandResult{
		exitCode: result.ExitCode, stdout: result.Stdout, stderr: result.Stderr,
	}, streamExpect); err != nil {
		return err
	}
	if (requireJSON && expect.Status == "success") || len(expect.JSON) > 0 {
		if err := checkJSONAssertions(result.Stdout, expect.JSON); err != nil {
			return err
		}
	}
	return nil
}

func validateJSONPointers(assertions map[string]any) error {
	for pointer := range assertions {
		if _, err := parseJSONPointer(pointer); err != nil {
			return err
		}
	}
	return nil
}

func checkJSONAssertions(stdout string, assertions map[string]any) error {
	var document any
	if err := json.Unmarshal([]byte(stdout), &document); err != nil {
		return fmt.Errorf("stdout is not valid JSON: %w\nstdout:\n%s", err, stdout)
	}
	pointers := make([]string, 0, len(assertions))
	for pointer := range assertions {
		pointers = append(pointers, pointer)
	}
	sort.Strings(pointers)
	for _, pointer := range pointers {
		actual, err := resolveJSONPointer(document, pointer)
		if err != nil {
			return err
		}
		expected, err := normalizeJSONValue(assertions[pointer])
		if err != nil {
			return fmt.Errorf("JSON pointer %q expectation: %w", pointer, err)
		}
		if !reflect.DeepEqual(actual, expected) {
			return fmt.Errorf("JSON pointer %q = %s, expected %s",
				pointer, jsonValue(actual), jsonValue(expected))
		}
	}
	return nil
}

func parseJSONPointer(pointer string) ([]string, error) {
	if pointer == "" {
		return nil, nil
	}
	if !strings.HasPrefix(pointer, "/") {
		return nil, fmt.Errorf("JSON pointer %q must be empty or start with /", pointer)
	}
	encoded := strings.Split(pointer[1:], "/")
	tokens := make([]string, 0, len(encoded))
	for _, token := range encoded {
		var decoded strings.Builder
		for i := 0; i < len(token); i++ {
			if token[i] != '~' {
				decoded.WriteByte(token[i])
				continue
			}
			if i+1 >= len(token) || token[i+1] != '0' && token[i+1] != '1' {
				return nil, fmt.Errorf("JSON pointer %q has invalid escape", pointer)
			}
			i++
			if token[i] == '0' {
				decoded.WriteByte('~')
			} else {
				decoded.WriteByte('/')
			}
		}
		tokens = append(tokens, decoded.String())
	}
	return tokens, nil
}

func resolveJSONPointer(document any, pointer string) (any, error) {
	tokens, err := parseJSONPointer(pointer)
	if err != nil {
		return nil, err
	}
	current := document
	for _, token := range tokens {
		switch value := current.(type) {
		case map[string]any:
			next, ok := value[token]
			if !ok {
				return nil, fmt.Errorf("JSON pointer %q has no object key %q", pointer, token)
			}
			current = next
		case []any:
			if token == "" || token != "0" && strings.HasPrefix(token, "0") {
				return nil, fmt.Errorf("JSON pointer %q has invalid array index %q", pointer, token)
			}
			index, err := strconv.Atoi(token)
			if err != nil || index < 0 || index >= len(value) {
				return nil, fmt.Errorf("JSON pointer %q has out-of-range array index %q", pointer, token)
			}
			current = value[index]
		default:
			return nil, fmt.Errorf("JSON pointer %q cannot traverse %q", pointer, token)
		}
	}
	return current, nil
}

func normalizeJSONValue(value any) (any, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var normalized any
	if err := json.Unmarshal(encoded, &normalized); err != nil {
		return nil, err
	}
	return normalized, nil
}

func jsonValue(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return fmt.Sprint(value)
	}
	return string(encoded)
}

func checkSecretCanaries(keys []string, env map[string]string, result actionResult, eventLog string) error {
	if len(keys) == 0 {
		return nil
	}
	events, err := os.ReadFile(eventLog)
	if err != nil {
		return fmt.Errorf("read event log for secret assertion: %w", err)
	}
	surfaces := map[string]string{
		"stdout": result.Stdout, "stderr": result.Stderr, "reason": result.Reason,
		"error": result.Error, "parser_error": result.ParserError, "event log": string(events),
	}
	for _, key := range keys {
		for _, canary := range canaryPattern.FindAllString(env[key], -1) {
			for surface, value := range surfaces {
				if strings.Contains(value, canary) {
					return fmt.Errorf("secret canary %s leaked in %s", key, surface)
				}
			}
		}
	}
	return nil
}

func argumentValue(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func environment(base []string, overrides map[string]string) []string {
	values := environmentMap(base)
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

func environmentMap(base []string) map[string]string {
	values := make(map[string]string, len(base))
	for _, entry := range base {
		key, value, found := strings.Cut(entry, "=")
		if found {
			values[key] = value
		}
	}
	return values
}

func withoutEnvironment(base []string, keys []string) []string {
	if len(keys) == 0 {
		return base
	}
	unset := make(map[string]bool, len(keys))
	for _, key := range keys {
		unset[key] = true
	}
	filtered := make([]string, 0, len(base))
	for _, entry := range base {
		key, _, ok := strings.Cut(entry, "=")
		if !ok || !unset[key] {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func indent(value string) string {
	return "  " + strings.ReplaceAll(strings.TrimSpace(value), "\n", "\n  ")
}
