package devtool

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

var (
	ansiPattern      = regexp.MustCompile(`\x1b\[[0-9;]*[[:alpha:]]`)
	pollutionPattern = regexp.MustCompile(`(?mi)(^|[[:space:]])warning:|\[(error|warning)\]|(^|[[:space:]])error:|Postgrex\.Protocol .*disconnected|DBConnection\.ConnectionError`)
)

func (a *App) runCaptured(ctx context.Context, label, dir string, env map[string]string, name string, args ...string) error {
	return a.gatePhase(label, func() error {
		command := exec.CommandContext(ctx, name, args...)
		command.Dir = dir
		command.Env = toolutil.MergedEnv(env)
		command.Stdin = a.In
		var output bytes.Buffer
		command.Stdout, command.Stderr = &output, &output
		err := command.Run()
		clean := ansiPattern.ReplaceAllString(output.String(), "")
		if err != nil {
			copyOutput(a.Out, output.Bytes())
			return err
		}
		if matches := pollutionPattern.FindAllString(clean, -1); len(matches) > 0 {
			for lineNumber, line := range strings.Split(clean, "\n") {
				if pollutionPattern.MatchString(line) {
					fmt.Fprintf(a.Err, "%d:%s\n", lineNumber+1, line)
				}
			}
			copyOutput(a.Out, output.Bytes())
			return fmt.Errorf("polluted test output; fix the warning/error/log source")
		}
		copyOutput(a.Out, output.Bytes())
		return nil
	})
}

type portalTestSuite struct {
	name      string
	partition string
	dir       string
	args      []string
}

type portalTestSuiteResult struct {
	suite    portalTestSuite
	output   []byte
	duration time.Duration
	err      error
}

func (a *App) portalTestSuites() []portalTestSuite {
	return []portalTestSuite{
		{
			name:      "emisar",
			partition: "_emisar",
			dir:       filepath.Join(a.Portal, "apps", "emisar"),
			args:      []string{"test", "--no-compile"},
		},
		{
			name:      "emisar_web",
			partition: "_emisar_web",
			dir:       filepath.Join(a.Portal, "apps", "emisar_web"),
			// Bypass emisar_web's test alias because the shard prepares its
			// partition once before the captured test run.
			args: []string{"cmd", "mix", "test", "--no-compile"},
		},
	}
}

func cloneEnv(env map[string]string) map[string]string {
	cloned := make(map[string]string, len(env)+2)
	for key, value := range env {
		cloned[key] = value
	}
	return cloned
}

func (a *App) portalTestOutput(ctx context.Context, env map[string]string, suites []portalTestSuite, profile bool) error {
	if len(suites) == 0 {
		fmt.Fprintln(a.Out, "no Portal test suites selected")
		return nil
	}

	if len(suites) > 1 {
		fmt.Fprintln(a.Out, "running Portal test suites in parallel")
	} else {
		fmt.Fprintln(a.Out, "running affected Portal test suite")
	}
	started := time.Now()
	maxCases := portalTestMaxCases(len(suites))
	results := make(chan portalTestSuiteResult, len(suites))
	for _, suite := range suites {
		suite.args = append(suite.args, "--max-cases", strconv.Itoa(maxCases))
		go func() {
			results <- a.runPortalTestSuite(ctx, env, suite, profile)
		}()
	}

	ordered := make(map[string]portalTestSuiteResult, len(suites))
	for range suites {
		result := <-results
		ordered[result.suite.name] = result
	}

	var firstErr error
	for _, suite := range suites {
		result := ordered[suite.name]
		fmt.Fprintf(a.Out, "\n--- %s test shard (%s) ---\n", suite.name, result.duration.Round(time.Millisecond))
		copyOutput(a.Out, result.output)
		if result.err != nil && firstErr == nil {
			firstErr = fmt.Errorf("%s test shard: %w", suite.name, result.err)
		}
	}
	if firstErr != nil {
		return firstErr
	}
	fmt.Fprintf(a.Out, "ok: Portal test output is clean (%s wall time)\n", elapsedLabel(started))
	return nil
}

func portalTestMaxCases(suiteCount int) int {
	availableCPUs := runtime.GOMAXPROCS(0)
	if suiteCount > 1 {
		// Two BEAM runtimes contend for the same host. Keep their combined
		// ExUnit case concurrency at the CPU count instead of allowing each
		// process to take Mix's default of twice that count.
		return max(1, availableCPUs/2)
	}
	return availableCPUs * 2
}

func (a *App) runPortalTestSuite(ctx context.Context, env map[string]string, suite portalTestSuite, profile bool) portalTestSuiteResult {
	started := time.Now()
	var output bytes.Buffer
	shard := *a
	// Gate shards are non-interactive. Sharing a buffered stdin reader between
	// two exec copies races and could split accidental input unpredictably.
	shard.In = nil
	shard.Out = &output
	shard.Err = &output
	testEnv := cloneEnv(env)
	testEnv["MIX_ENV"] = "test"
	testEnv["MIX_TEST_PARTITION"] = suite.partition
	if profile {
		testEnv["EMISAR_TEST_PROFILE"] = "1"
	}

	result := portalTestSuiteResult{suite: suite}
	lock, err := shard.portalTestLock(testEnv)
	if err == nil {
		defer releasePortalTestLock(lock)
		err = shard.ensurePortalTestDatabase(ctx, testEnv)
	}
	if err == nil {
		err = shard.runCaptured(ctx, suite.name+" app tests", suite.dir, testEnv, "mix", suite.args...)
	}
	result.output = output.Bytes()
	result.duration = time.Since(started)
	result.err = err
	return result
}

func (a *App) warmPortalTestDependencies(ctx context.Context, env map[string]string) error {
	return a.gatePhase("deps warm-up (unscanned third-party output)", func() error {
		if err := a.run(ctx, a.Portal, env, "mix", "deps.compile"); err != nil {
			return fmt.Errorf("deps compile failed: %w", err)
		}
		return nil
	})
}

func (a *App) ensurePortalTestDatabase(ctx context.Context, env map[string]string) error {
	dir := filepath.Join(a.Portal, "apps", "emisar")
	for _, check := range []struct {
		label string
		args  []string
	}{
		{"database setup", []string{"ecto.create", "--quiet"}},
		{"database migrations", []string{"ecto.migrate", "--quiet"}},
	} {
		if err := a.runCaptured(ctx, check.label, dir, env, "mix", check.args...); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) changedPortalFiles(ctx context.Context) ([]string, error) {
	changed, err := a.output(ctx, a.Root, nil, "git", "diff", "--name-only", "-z", "--diff-filter=ACMRD", "HEAD", "--", "portal")
	if err != nil {
		return nil, err
	}
	untracked, err := a.output(ctx, a.Root, nil, "git", "ls-files", "-z", "--others", "--exclude-standard", "--", "portal")
	if err != nil {
		return nil, err
	}
	set := make(map[string]struct{})
	for _, path := range append(toolutil.NULFields(changed), toolutil.NULFields(untracked)...) {
		set[path] = struct{}{}
	}
	paths := make([]string, 0, len(set))
	for path := range set {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths, nil
}

func (a *App) changedPortalCheck(ctx context.Context) error {
	paths, err := a.changedPortalFiles(ctx)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		fmt.Fprintln(a.Out, "no changed Portal files")
		return nil
	}
	return a.checkChangedPortalPaths(ctx, paths)
}

func (a *App) checkChangedPortalPaths(ctx context.Context, paths []string) error {
	formatFiles, credoFiles := []string{}, []string{}
	migrationsChanged := false
	for _, path := range paths {
		absolute := filepath.Join(a.Root, filepath.FromSlash(path))
		if strings.HasPrefix(path, portalMigrationsDir+"/") {
			migrationsChanged = true
		}
		if info, statErr := os.Stat(absolute); statErr != nil || info.IsDir() {
			continue
		}
		relative := strings.TrimPrefix(path, "portal/")
		switch filepath.Ext(relative) {
		case ".ex", ".exs":
			formatFiles = append(formatFiles, relative)
			credoFiles = append(credoFiles, relative)
		case ".heex":
			formatFiles = append(formatFiles, relative)
		}
	}
	if migrationsChanged {
		if err := a.checkNewMigrationsSortLast(ctx); err != nil {
			return err
		}
	}
	if len(formatFiles) == 0 && len(credoFiles) == 0 {
		fmt.Fprintln(a.Out, "no changed Portal source files")
		return nil
	}
	if err := a.run(ctx, a.Portal, nil, "mix", "compile", "--warnings-as-errors"); err != nil {
		return err
	}
	if len(formatFiles) > 0 {
		fmt.Fprintf(a.Out, "Checking format: %s\n", strings.Join(formatFiles, " "))
		if err := a.run(ctx, a.Portal, nil, "mix", append([]string{"format", "--check-formatted"}, formatFiles...)...); err != nil {
			return err
		}
	}
	if len(credoFiles) > 0 {
		fmt.Fprintf(a.Out, "Checking Credo: %s\n", strings.Join(credoFiles, " "))
		if err := a.run(ctx, a.Portal, nil, "mix", append([]string{"credo"}, credoFiles...)...); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) changedPortalGate(ctx context.Context) error {
	paths, err := a.changedPortalFiles(ctx)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		fmt.Fprintln(a.Out, "no changed Portal files")
		return nil
	}
	if err := a.checkChangedPortalPaths(ctx, paths); err != nil {
		return err
	}
	suites := a.changedPortalTestSuites(paths)
	if len(suites) == 0 {
		fmt.Fprintln(a.Out, "no Portal tests needed for documentation-only changes")
		return nil
	}
	testEnv, err := a.portalTestEnv(ctx)
	if err != nil {
		return err
	}
	if err := a.gatePhase("changed Portal test compile", func() error {
		return a.run(ctx, a.Portal, testEnv, "mix", "compile", "--warnings-as-errors")
	}); err != nil {
		return err
	}
	return a.gatePhase("affected Portal test suites", func() error {
		return a.portalTestOutput(ctx, testEnv, suites, false)
	})
}

func (a *App) changedPortalTestSuites(paths []string) []portalTestSuite {
	suites := a.portalTestSuites()
	core, web := false, false
	for _, path := range paths {
		relative := strings.TrimPrefix(filepath.ToSlash(path), "portal/")
		if strings.HasPrefix(relative, ".agent/") || filepath.Ext(relative) == ".md" {
			continue
		}
		switch {
		case strings.HasPrefix(relative, "apps/emisar_web/"):
			web = true
		case strings.HasPrefix(relative, "apps/emisar/"):
			core, web = true, true
		default:
			core, web = true, true
		}
	}
	selected := make([]portalTestSuite, 0, 2)
	if core {
		selected = append(selected, suites[0])
	}
	if web {
		selected = append(selected, suites[1])
	}
	return selected
}

func portalTestInvocation(portal string, args []string) (string, []string, error) {
	app := ""
	for _, argument := range args {
		candidate := ""
		switch {
		case strings.HasPrefix(argument, "apps/emisar/"), strings.HasPrefix(argument, "test/emisar/"):
			candidate = "emisar"
		case strings.HasPrefix(argument, "apps/emisar_web/"), strings.HasPrefix(argument, "test/emisar_web/"):
			candidate = "emisar_web"
		}
		if candidate != "" && app != "" && candidate != app {
			return "", nil, usage("focused test paths must belong to one Portal app")
		}
		if candidate != "" {
			app = candidate
		}
	}
	if app == "" {
		return portal, append([]string{"test"}, args...), nil
	}
	appArgs := make([]string, 0, len(args)+1)
	appArgs = append(appArgs, "test")
	for _, argument := range args {
		if strings.HasPrefix(argument, "apps/"+app+"/") {
			appArgs = append(appArgs, strings.TrimPrefix(argument, "apps/"+app+"/"))
		} else if strings.HasPrefix(argument, "apps/emisar/") || strings.HasPrefix(argument, "apps/emisar_web/") {
			return "", nil, usage("focused test paths must belong to one Portal app")
		} else {
			appArgs = append(appArgs, argument)
		}
	}
	return filepath.Join(portal, "apps", app), appArgs, nil
}

func (a *App) portalTests(ctx context.Context, env map[string]string, args []string, profile bool) error {
	dir, testArgs, err := portalTestInvocation(a.Portal, args)
	if err != nil {
		return err
	}
	testEnv := make(map[string]string, len(env)+1)
	for key, value := range env {
		testEnv[key] = value
	}
	testEnv["MIX_ENV"] = "test"
	if profile {
		testEnv["EMISAR_TEST_PROFILE"] = "1"
	}
	// A focused run is the usual victim rather than the cause — it holds no
	// migration of its own, and a gate migrating alongside it is what cancels
	// its queries. Same lock, so the two cannot overlap either way round.
	lock, err := a.portalTestLock(testEnv)
	if err != nil {
		return err
	}
	defer releasePortalTestLock(lock)
	return a.run(ctx, dir, testEnv, "mix", testArgs...)
}

func portalTestMode(args []string) ([]string, bool, error) {
	clean := make([]string, 0, len(args))
	profile := false
	for _, argument := range args {
		if argument != "--profile" {
			clean = append(clean, argument)
			continue
		}
		if profile {
			return nil, false, usage("--profile may be passed only once")
		}
		profile = true
	}
	return clean, profile, nil
}

func (a *App) portalProfile(ctx context.Context, env map[string]string) error {
	testEnv := cloneEnv(env)
	testEnv["MIX_ENV"] = "test"
	if err := a.gatePhase("Portal profile compile", func() error {
		return a.run(ctx, a.Portal, testEnv, "mix", "compile", "--warnings-as-errors")
	}); err != nil {
		return err
	}
	return a.gatePhase("Portal test profile", func() error {
		return a.portalTestOutput(ctx, testEnv, a.portalTestSuites(), true)
	})
}

func (a *App) documentationCheck(ctx context.Context) error {
	return a.run(ctx, filepath.Join(a.Root, "tools"), nil, "go", "run", "./cmd/doccheck")
}

func (a *App) agentSetupCheck(ctx context.Context, requireCoop bool) error {
	args := []string{"run", "./tools/cmd/agentcheck"}
	if requireCoop {
		args = append(args, "--require-coop")
	}
	return a.run(ctx, a.Root, nil, "go", args...)
}

func (a *App) toolingGate(ctx context.Context, coverage string) error {
	if err := a.goGate(ctx, "tools", coverage); err != nil {
		return err
	}
	if err := a.gatePhase("tooling documentation", func() error {
		return a.documentationCheck(ctx)
	}); err != nil {
		return err
	}
	// The workflows ARE the supply chain's front door — lint them like code:
	// expression injection, wrong event fields, invalid globs. Pinned so a new
	// actionlint release cannot fail an unchanged tree; `go run` keeps it off
	// the contributor's PATH, same as staticcheck.
	if err := a.gatePhase("tooling workflow lint", func() error {
		return a.lintWorkflows(ctx)
	}); err != nil {
		return err
	}
	if err := a.gatePhase("tooling agent setup", func() error {
		return a.agentSetupCheck(ctx, false)
	}); err != nil {
		return err
	}
	if err := a.gatePhase("tooling e2e stack versions", func() error {
		return a.checkComposeVersionsMatchCompat(ctx)
	}); err != nil {
		return err
	}
	if err := a.gatePhase("tooling shared service image pins", a.checkSharedServiceImagePins); err != nil {
		return err
	}
	if err := a.gatePhase("tooling release toolchain", a.checkReleaseToolchainPins); err != nil {
		return err
	}
	// dep-age is a required check, so it belongs here rather than only in a CI
	// step: it already defaults its base to origin/main because it was written to
	// run on a workstation, and it reads immutable publish dates, not a live
	// advisory feed. As a CI-only step a green `./run gate all` still failed CI.
	if err := a.gatePhase("tooling dependency age", func() error {
		return a.depAgeCheck(ctx, nil)
	}); err != nil {
		return err
	}
	scripts, err := a.trackedShellFiles(ctx)
	if err != nil {
		return err
	}
	// Fail rather than skip. A broken pathspec — a rename, a moved directory —
	// used to make this phase pass by selecting nothing, which is the shape of a
	// check that silently stops checking.
	if len(scripts) == 0 {
		return fmt.Errorf("no tracked shell scripts matched the lint pathspec")
	}
	if err := a.gatePhase("tooling shell scripts", func() error {
		if err := a.run(ctx, a.Root, nil, "shellcheck", scripts...); err != nil {
			return err
		}
		for _, script := range scripts {
			if err := a.run(ctx, a.Root, nil, "bash", "-n", script); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "development tooling checks passed")
	return nil
}

func (a *App) lintWorkflows(ctx context.Context) error {
	regular, selfReferenced, err := workflowLintPaths(a.Root)
	if err != nil {
		return err
	}
	if len(regular) != 0 {
		args := append([]string{"run", actionlintVersion, "-color"}, regular...)
		if err := a.run(ctx, a.Root, nil, "go", args...); err != nil {
			return fmt.Errorf("workflow lint findings: %w", err)
		}
	}
	if len(selfReferenced) != 0 {
		args := []string{
			"run", actionlintVersion, "-color",
			"-ignore", actionlintSelfReferenceFalsePositive,
		}
		args = append(args, selfReferenced...)
		if err := a.run(ctx, a.Root, nil, "go", args...); err != nil {
			return fmt.Errorf("trusted workflow lint findings: %w", err)
		}
	}
	return nil
}

func workflowLintPaths(root string) (regular, selfReferenced []string, err error) {
	var paths []string
	for _, pattern := range []string{"*.yml", "*.yaml"} {
		matched, globErr := filepath.Glob(filepath.Join(root, ".github", "workflows", pattern))
		if globErr != nil {
			return nil, nil, globErr
		}
		paths = append(paths, matched...)
	}
	sort.Strings(paths)
	for _, path := range paths {
		if trustedReleaseWorkflowNames[filepath.Base(path)] {
			selfReferenced = append(selfReferenced, path)
		} else {
			regular = append(regular, path)
		}
	}
	return regular, selfReferenced, nil
}

// trackedShellFiles is the repo's own shell scripts that no other gate covers.
// It was scoped to `.shell run dev`, which matched three files out of seventy,
// leaving the release-image verifier, the commit-gate hook, and the sweep queue
// guard linted nowhere.
//
// The exclusions are all "some other gate owns this, and owns it better":
// the two public installers get their own phase in `./run gate runner|mcp`;
// infra/runtime scripts are cloud-init TEMPLATES whose Terraform interpolation
// only becomes valid shell once rendered, so the infra gate shellchecks them
// after rendering; pack action scripts get a parse check from the packs gate,
// which knows each one's declared interpreter; and pack test fixtures are
// deliberately malformed inputs.
func (a *App) trackedShellFiles(ctx context.Context) ([]string, error) {
	data, err := a.output(ctx, a.Root, nil, "git", "ls-files", "-z", "--",
		".shell", "run", "*.sh", ".githooks",
		":(exclude)install.sh", ":(exclude)install-mcp.sh",
		":(exclude)infra/runtime/*", ":(exclude)packs/*")
	if err != nil {
		return nil, err
	}
	var scripts []string
	for _, path := range toolutil.NULFields(data) {
		// The git hooks are tracked #!/bin/sh scripts with no extension, so an
		// extension filter linted none of them — and pre-commit is the entry
		// point to `./run check staged`, where a syntax error disables the
		// commit gate quietly.
		if path != ".shell" && path != "run" &&
			!strings.HasPrefix(path, ".githooks/") && filepath.Ext(path) != ".sh" {
			continue
		}
		if info, statErr := os.Stat(filepath.Join(a.Root, filepath.FromSlash(path))); statErr == nil && !info.IsDir() {
			scripts = append(scripts, path)
		}
	}
	return scripts, nil
}

func (a *App) check(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return usage("%s", checkUsage)
	}
	target, rest := args[0], args[1:]
	switch target {
	case "changed":
		if len(rest) != 0 {
			return usage("usage: ./run check changed")
		}
		return a.changedPortalCheck(ctx)
	case "docs":
		if len(rest) != 0 {
			return usage("usage: ./run check docs")
		}
		return a.documentationCheck(ctx)
	case "portal":
		if len(rest) != 0 {
			return usage("usage: ./run check portal")
		}
		for _, arguments := range [][]string{{"compile", "--warnings-as-errors"}, {"format", "--check-formatted"}, {"credo"}} {
			if err := a.run(ctx, a.Portal, nil, "mix", arguments...); err != nil {
				return err
			}
		}
		return nil
	case "staged":
		if len(rest) != 0 {
			return usage("usage: ./run check staged")
		}
		return a.stagedCheck(ctx)
	case "infra-templates":
		if len(rest) != 0 {
			return usage("usage: ./run check infra-templates")
		}
		return a.infraOps(ctx, []string{"validate-templates"})
	case "packs":
		if len(rest) != 0 {
			return usage("usage: ./run check packs")
		}
		return a.validatePacks(ctx)
	case "agent-setup":
		if len(rest) != 0 {
			return usage("usage: ./run check agent-setup")
		}
		return a.agentSetupCheck(ctx, true)
	case "deps":
		return a.depAgeCheck(ctx, rest)
	default:
		return usage("%s", checkUsage)
	}
}

// depAgeCheck enforces the dependency release-age and non-registry-source
// rules. It diffs manifests against a base ref (--base, default origin/main)
// and no-ops when none changed, so it is cheap on an unchanged tree; with no
// resolvable base it skips rather than treating every existing dependency as
// newly added.
func (a *App) depAgeCheck(ctx context.Context, rest []string) error {
	args := append([]string{"run", "./cmd/depgate", "check"}, rest...)
	return a.run(ctx, filepath.Join(a.Root, "tools"), nil, "go", args...)
}
