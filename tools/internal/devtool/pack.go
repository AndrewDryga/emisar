package devtool

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/packhash"
	"github.com/andrewdryga/emisar/tools/internal/packtest"
	"go.yaml.in/yaml/v3"
)

func (a *App) buildPackTools(ctx context.Context) error {
	bin := filepath.Join(a.Root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		return err
	}
	if err := a.run(ctx, filepath.Join(a.Root, "runner"), nil, "go", "build", "-trimpath", "-o", filepath.Join(bin, "emisar"), "."); err != nil {
		return err
	}
	return a.run(ctx, filepath.Join(a.Root, "runner"), nil, "go", "build", "-trimpath", "-o", filepath.Join(bin, "packctl"), "./cmd/packctl")
}

func (a *App) packSync(ctx context.Context, name string) error {
	response, err := http.Get("https://registry.emisar.dev/v1/catalog.json")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("registry catalog: HTTP %s", response.Status)
	}
	previous, err := os.CreateTemp("", "emisar-catalog-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(previous.Name())
	if _, err := io.Copy(previous, response.Body); err != nil {
		previous.Close()
		return err
	}
	if err := previous.Close(); err != nil {
		return err
	}
	output := filepath.Join(a.Root, "dist", "packs")
	if err := os.RemoveAll(output); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "packctl"), "catalog", "build", "--packs", filepath.Join(a.Root, "packs"), "--out", output, "--previous", previous.Name()); err != nil {
		return err
	}
	catalog, err := os.ReadFile(filepath.Join(output, "v1", "catalog.json"))
	if err != nil {
		return err
	}
	if err := atomicWrite(filepath.Join(a.Portal, "apps", "emisar", "priv", "packs", "catalog.json"), catalog, 0o644); err != nil {
		return err
	}
	// These verification tests need the same database env the packs gate builds.
	// Passing nil left PGPORT unset, so on a workstation whose Postgres is on a
	// compose-assigned port the run silently blocked on :5432 until it timed out
	// — a hang that reads as a wedged build rather than a missing service.
	env, err := a.portalTestEnv(ctx)
	if err != nil {
		return err
	}
	registryTests := []string{
		"test/emisar/catalog/pack_baseline_test.exs",
		"test/emisar/catalog/published_registry_test.exs",
		"test/emisar/catalog/published_registry/cache_test.exs",
	}
	if err := a.run(ctx, filepath.Join(a.Portal, "apps", "emisar"), env, "mix", append([]string{"test"}, registryTests...)...); err != nil {
		return err
	}
	return a.run(ctx, filepath.Join(a.Portal, "apps", "emisar_web"), env, "mix", "test", "test/emisar_web/packs_test.exs")
}

func (a *App) packTest(ctx context.Context, pattern string, names []string, caseID, shard string, hostile bool) error {
	harness := filepath.Join(a.Root, "dev", "test-packs")
	plans, err := packtest.Discover(filepath.Join(a.Root, "packs"), pattern, names...)
	if err != nil {
		return err
	}
	plans, err = selectPackTestShard(plans, shard)
	if err != nil {
		return err
	}
	plans, err = selectPackTestCase(plans, caseID)
	if err != nil {
		return err
	}
	requestedVersionEnv, err := packTestVersionEnv(len(plans), os.LookupEnv)
	if err != nil {
		return err
	}
	invocationID := packTestInvocationID(time.Now(), os.Getpid())
	reports := filepath.Join(harness, "reports", invocationID)
	if err := os.MkdirAll(reports, 0o755); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "Reports: %s\n", filepath.Join("dev", "test-packs", "reports", invocationID))
	if err := packtest.Validate(plans); err != nil {
		return errors.Join(err, writePackTestFailureReports(reports, plans, requestedVersionEnv, err))
	}
	bin := filepath.Join(harness, "bin")
	baseCompose := filepath.Join(harness, "compose.yaml")
	runnerImage, runnerImageErr := packTestRunnerImage(a.Root)
	sharedTools, sharedToolsErr := packTestNeedsSharedTools(plans)
	preflightErr := func() error {
		if err := errors.Join(runnerImageErr, sharedToolsErr); err != nil {
			return err
		}
		if err := os.MkdirAll(bin, 0o755); err != nil {
			return err
		}
		env := map[string]string{"GOOS": "linux", "GOARCH": runtime.GOARCH, "CGO_ENABLED": "0"}
		if err := a.run(ctx, filepath.Join(a.Root, "runner"), env, "go", "build", "-trimpath", "-o", filepath.Join(bin, "emisar"), "."); err != nil {
			return err
		}
		if err := a.run(ctx, filepath.Join(a.Root, "tools"), env, "go", "build", "-trimpath", "-o", filepath.Join(bin, "packtest"), "./cmd/packtest"); err != nil {
			return err
		}
		if !sharedTools || a.hasImage(ctx, runnerImage) {
			return nil
		}
		composeEnv := map[string]string{
			"EMISAR_ROOT":           a.Root,
			"PACKTEST_RUNNER_IMAGE": runnerImage,
		}
		return a.run(ctx, a.Root, composeEnv, "docker", "compose", "-f", baseCompose, "build", "runner-tools")
	}()
	if preflightErr != nil {
		return errors.Join(preflightErr, writePackTestFailureReports(reports, plans, requestedVersionEnv, preflightErr))
	}

	versionEnvs := make(map[string]map[string]string, len(plans))
	images := make(map[string]string, len(plans))
	overrides := make(map[string]string, len(plans))
	var mirrors []packtest.MirrorRow
	mirrorRegistry := strings.TrimSpace(os.Getenv("PACKTEST_MIRROR_REGISTRY"))
	if mirrorRegistry != "" {
		mirrors, err = packtest.Mirrors(
			filepath.Join(a.Root, "packs"),
			filepath.Join(a.Root, "dev", "test-packs", "mirrors.yaml"),
			mirrorRegistry,
		)
		if err != nil {
			return err
		}
	}
	for _, plan := range plans {
		versionEnv := resolvedPackTestVersionEnv(plan, requestedVersionEnv)
		if mirror, ok := packtest.ResolveMirror(
			mirrors, plan.Name, versionEnv["PACKTEST_VERSION"], versionEnv["PACKTEST_DIGEST"],
		); ok {
			versionEnv["PACKTEST_IMAGE"] = mirror.MirrorRef
			fmt.Fprintf(a.Out, "SUT mirror: %s -> %s\n", mirror.SourceRef, mirror.MirrorRef)
		}
		versionEnvs[plan.Name] = versionEnv
		if hostile {
			override, err := writePackTestHostileOverride(reports, plan)
			if err != nil {
				return err
			}
			overrides[plan.Name] = override
			fmt.Fprintf(a.Out, "Hostile limits: %s (1 CPU, 1536 MiB, 512 PIDs per SUT)\n", plan.Name)
		}
		resolved, err := a.preparePackTestPlan(ctx, baseCompose, overrides[plan.Name], invocationID, runnerImage, plan, versionEnv)
		if err != nil {
			return errors.Join(err, writePackTestFailureReports(reports, []packtest.PlanRef{plan}, requestedVersionEnv, err))
		}
		images[plan.Name] = resolved
	}

	var queued []packTestJob
	for _, plan := range plans {
		for _, test := range plan.Cases {
			queued = append(queued, packTestJob{
				InvocationID: invocationID,
				Plan:         plan,
				Case:         test,
				VersionEnv:   versionEnvs[plan.Name],
				Images:       images[plan.Name],
				ComposeExtra: overrides[plan.Name],
			})
		}
	}
	jobs := make(chan packTestJob, len(queued))
	results := make(chan packTestCaseResult, len(queued))
	for _, job := range queued {
		jobs <- job
	}
	close(jobs)

	workerCount := min(packtest.Workers(plans), len(queued))
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for range workerCount {
		go func() {
			defer workers.Done()
			for job := range jobs {
				var output bytes.Buffer
				writePackTestReportHeader(&output, job.Plan, job.Case.ID, job.VersionEnv, job.Case.RunnerUser)
				worker := New(a.Root, nil, &output, &output)
				started := time.Now()
				runErr := worker.runPackTestCase(ctx, baseCompose, runnerImage, job)
				duration := time.Since(started).Round(time.Millisecond)
				fmt.Fprintf(&output, "\nCase duration: %s\n", duration)
				if runErr != nil {
					fmt.Fprintf(&output, "\nError: %v\n", runErr)
				}
				results <- packTestCaseResult{
					Plan: job.Plan, Case: job.Case, Duration: duration,
					Output: output.Bytes(), Err: runErr,
				}
			}
		}()
	}
	go func() {
		workers.Wait()
		close(results)
	}()

	completed := make([]packTestCaseResult, 0, len(queued))
	for result := range results {
		reportDir := filepath.Join(reports, result.Plan.Name)
		if err := os.MkdirAll(reportDir, 0o755); err != nil {
			result.Err = errors.Join(result.Err, fmt.Errorf("create report directory: %w", err))
		}
		reportPath := filepath.Join(reportDir, result.Case.ID+".log")
		if err := os.WriteFile(reportPath, result.Output, 0o644); err != nil {
			result.Err = errors.Join(result.Err, fmt.Errorf("write report: %w", err))
		}
		completed = append(completed, result)
		status := "PASS"
		if result.Err != nil {
			status = "FAIL"
		}
		fmt.Fprintf(a.Out, "[%d/%d] %s %s/%s (%s)\n",
			len(completed), len(queued), status, result.Plan.Name, result.Case.ID, result.Duration)
	}
	sort.Slice(completed, func(i, j int) bool {
		if completed[i].Plan.Name != completed[j].Plan.Name {
			return completed[i].Plan.Name < completed[j].Plan.Name
		}
		return completed[i].Case.ID < completed[j].Case.ID
	})

	var failures []error
	var aggregate bytes.Buffer
	currentPack := ""
	for index, result := range completed {
		if result.Plan.Name != currentPack {
			if currentPack != "" {
				if err := os.WriteFile(filepath.Join(reports, currentPack+".log"), aggregate.Bytes(), 0o644); err != nil {
					failures = append(failures, err)
				}
				aggregate.Reset()
			}
			currentPack = result.Plan.Name
			writePackTestReportHeader(&aggregate, result.Plan, "all", versionEnvs[result.Plan.Name], result.Plan.Runner.User)
		}
		if result.Err != nil {
			fmt.Fprintf(a.Out, "\n--- %s/%s ---\n", result.Plan.Name, result.Case.ID)
			copyOutput(a.Out, result.Output)
		}
		fmt.Fprintf(&aggregate, "\n--- %s ---\n", result.Case.ID)
		copyOutput(&aggregate, result.Output)
		if result.Err != nil {
			failures = append(failures, fmt.Errorf("%s/%s: %w", result.Plan.Name, result.Case.ID, result.Err))
		}
		if index == len(completed)-1 {
			if err := os.WriteFile(filepath.Join(reports, currentPack+".log"), aggregate.Bytes(), 0o644); err != nil {
				failures = append(failures, err)
			}
		}
	}
	if len(failures) == 0 {
		if limits := packTestHostBlindSpots(runtime.GOOS, a.dockerHostOS(ctx), runtime.NumCPU()); len(limits) > 0 {
			fmt.Fprintf(a.Out, "\n%s\n", packTestVerdictNotice(limits))
		}
	}
	return errors.Join(failures...)
}

// packTestHostBlindSpots names what this host's Docker cannot decide. A green
// run here is real evidence about an action's behavior and no evidence at all
// about the isolated, non-root SUT the Linux matrix runs: Docker Desktop's VM
// masks uid ownership and loads no AppArmor profile, and a workstation with
// cores to spare wins startup races a two-to-four core runner loses.
func packTestHostBlindSpots(goos, dockerOS string, cores int) []string {
	var limits []string
	if strings.Contains(dockerOS, "Docker Desktop") || goos != "linux" {
		limits = append(limits,
			"file ownership and permission errors — the VM masks container uid ownership",
			"anything AppArmor confines — no profile is loaded here",
		)
	}
	// A GitHub runner has four cores; more than that here wins races it loses.
	if goos != "linux" || cores > 4 {
		limits = append(limits,
			"startup races — a runner has fewer cores and loses races this host wins",
		)
	}
	return limits
}

func packTestVerdictNotice(limits []string) string {
	notice := "Passed here, which does not decide:\n"
	for _, limit := range limits {
		notice += "  - " + limit + "\n"
	}
	return notice + "The Linux pack behavior matrix is the authority for those. Read the job."
}

func (a *App) dockerHostOS(ctx context.Context) string {
	output, err := a.output(ctx, a.Root, nil, "docker", "info", "--format", "{{.OperatingSystem}}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

// selectPackTestShard keeps one slice of a single pack's cases. A pack whose
// SUT boots slowly costs its case count times that boot, so splitting it across
// matrix rows is what shortens the row without weakening the per-case isolation
// that makes the boot unavoidable.
func selectPackTestShard(plans []packtest.PlanRef, shard string) ([]packtest.PlanRef, error) {
	if shard == "" {
		return plans, nil
	}
	if len(plans) != 1 {
		return nil, fmt.Errorf("--shard requires a name that selects exactly one pack")
	}
	index, count, ok := strings.Cut(shard, "/")
	if !ok {
		return nil, fmt.Errorf("--shard takes <index>/<count>, not %q", shard)
	}
	selected, err := strconv.Atoi(index)
	if err != nil {
		return nil, fmt.Errorf("--shard index %q is not a number", index)
	}
	total, err := strconv.Atoi(count)
	if err != nil {
		return nil, fmt.Errorf("--shard count %q is not a number", count)
	}
	plan := plans[0]
	declared := max(plan.Shards, 1)
	if total != declared {
		return nil, fmt.Errorf("pack %s declares %d shards, not %d", plan.Name, declared, total)
	}
	if selected < 1 || selected > total {
		return nil, fmt.Errorf("--shard index %d is outside 1..%d", selected, total)
	}
	plan.Cases = packtest.SelectShard(plan.Cases, selected, total)
	return []packtest.PlanRef{plan}, nil
}

func selectPackTestCase(plans []packtest.PlanRef, caseID string) ([]packtest.PlanRef, error) {
	if caseID == "" {
		return plans, nil
	}
	if len(plans) != 1 {
		return nil, fmt.Errorf("--case requires a name that selects exactly one pack")
	}
	selected := plans[0]
	for _, test := range selected.Cases {
		if test.ID == caseID {
			selected.Cases = []packtest.CaseRef{test}
			return []packtest.PlanRef{selected}, nil
		}
	}
	return nil, fmt.Errorf("pack %s has no case %q", selected.Name, caseID)
}

func writePackTestFailureReports(dir string, plans []packtest.PlanRef, requested map[string]string, failure error) error {
	var failures []error
	for _, plan := range plans {
		var report bytes.Buffer
		versionEnv := resolvedPackTestVersionEnv(plan, requested)
		writePackTestReportHeader(&report, plan, "preflight", versionEnv, plan.Runner.User)
		fmt.Fprintf(&report, "Error: preflight: %v\n", failure)
		reportDir := filepath.Join(dir, plan.Name)
		if err := os.MkdirAll(reportDir, 0o755); err != nil {
			failures = append(failures, fmt.Errorf("create %s report directory: %w", plan.Name, err))
			continue
		}
		if err := os.WriteFile(filepath.Join(dir, plan.Name+".log"), report.Bytes(), 0o644); err != nil {
			failures = append(failures, fmt.Errorf("write %s report: %w", plan.Name, err))
		}
		if err := os.WriteFile(filepath.Join(reportDir, "preflight.log"), report.Bytes(), 0o644); err != nil {
			failures = append(failures, fmt.Errorf("write %s preflight report: %w", plan.Name, err))
		}
	}
	return errors.Join(failures...)
}

func writePackTestReportHeader(output io.Writer, plan packtest.PlanRef, caseID string, versionEnv map[string]string, user string) {
	if user == "" {
		user = "nonroot"
	}
	fmt.Fprintf(output, "Pack: %s\nPack version: %s\nCase: %s\nRunner user: %s\nSUT version: %s\nSUT digest: %s\n\n",
		plan.Name, plan.PackVersion, caseID, user,
		versionEnv["PACKTEST_VERSION"], versionEnv["PACKTEST_DIGEST"])
}

type packTestJob struct {
	InvocationID string
	Plan         packtest.PlanRef
	Case         packtest.CaseRef
	VersionEnv   map[string]string
	Images       string
	ComposeExtra string
}

type packTestCaseResult struct {
	Plan     packtest.PlanRef
	Case     packtest.CaseRef
	Duration time.Duration
	Output   []byte
	Err      error
}

func (a *App) preparePackTestPlan(
	ctx context.Context,
	baseCompose string,
	composeExtra string,
	invocationID string,
	runnerImage string,
	plan packtest.PlanRef,
	versionEnv map[string]string,
) (string, error) {
	packCompose := filepath.Join(filepath.Dir(plan.Path), "compose.yaml")
	if !isFile(packCompose) {
		return "", fmt.Errorf("behavior plan has no sibling compose.yaml")
	}
	if len(plan.Services) == 0 {
		return "", fmt.Errorf("behavior plan has no primary SUT service")
	}
	defaultVersion := plan.DefaultVersion()
	if err := validatePackTestVersionInput(packCompose, plan.Services[0], defaultVersion.Version); err != nil {
		return "", err
	}
	compose := packTestComposeArgs(baseCompose, packCompose, composeExtra)
	env := packTestComposeEnv(a.Root, invocationID, runnerImage, plan, "build", versionEnv, plan.Runner.User)

	output, err := a.output(ctx, a.Root, env, "docker", append(compose, "config", "--services")...)
	if err != nil {
		return "", err
	}
	available := make(map[string]bool)
	for _, service := range strings.Fields(string(output)) {
		available[service] = true
	}
	if !available["runner-tools"] {
		return "", fmt.Errorf("the Compose project has no runner-tools service")
	}
	for _, service := range plan.Services {
		if !available[service] {
			return "", fmt.Errorf("requires unknown Compose service %s", service)
		}
	}

	buildServices, err := packTestBuildServices(packCompose)
	if err != nil {
		return "", err
	}
	if len(buildServices) > 0 {
		buildArgs := append(append([]string{}, compose...), "build")
		buildArgs = append(buildArgs, buildServices...)
		if err := a.run(ctx, a.Root, env, "docker", buildArgs...); err != nil {
			return "", fmt.Errorf("build pack services: %w", err)
		}
	}

	// Pull once, here, rather than letting the first wave of cases race a pull
	// while their SUTs start. That wave was taking three times as long as the
	// rest and starving servers that boot on a timer.
	// --ignore-buildable: a pack that ships its own client or SUT image builds
	// it, and asking a registry for it fails.
	pull := append(append([]string{}, compose...), "pull", "--quiet", "--policy", "missing", "--ignore-buildable")
	if err := retryPackTestPull(ctx, packTestPullBackoff, a.Err, func() error {
		return a.run(ctx, a.Root, env, "docker", pull...)
	}); err != nil {
		return "", fmt.Errorf("pull pack images: %w", err)
	}

	// Only the project name and the runner identity vary between a plan's
	// cases, and neither reaches image resolution, so resolving here spares
	// every case a second full parse of both Compose files.
	images, err := a.output(ctx, a.Root, env, "docker", append(compose, "config", "--images")...)
	if err != nil {
		return "", err
	}
	return string(images), nil
}

// --policy missing leaves the pull above as the only registry read a plan
// makes, so one Docker Hub hiccup there fails the row — and on main, the
// deploy behind it. Anonymous pulls time out often enough at this matrix
// width to have already forced max-parallel down. A pull is a read: retrying
// one costs seconds where rerunning the job costs the pipeline.
const (
	packTestPullAttempts = 3
	packTestPullBackoff  = 3 * time.Second
)

func retryPackTestPull(ctx context.Context, backoff time.Duration, log io.Writer, pull func() error) error {
	var err error
	for attempt := 1; attempt <= packTestPullAttempts; attempt++ {
		if err = pull(); err == nil {
			return nil
		}
		if attempt == packTestPullAttempts {
			break
		}
		fmt.Fprintf(log, "pull failed (attempt %d of %d), retrying: %v\n", attempt, packTestPullAttempts, err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff * time.Duration(attempt)):
		}
	}
	return err
}

func (a *App) runPackTestCase(ctx context.Context, baseCompose, runnerImage string, job packTestJob) (err error) {
	packCompose := filepath.Join(filepath.Dir(job.Plan.Path), "compose.yaml")
	compose := packTestComposeArgs(baseCompose, packCompose, job.ComposeExtra)
	env := packTestComposeEnv(
		a.Root,
		job.InvocationID,
		runnerImage,
		job.Plan,
		job.Case.ID,
		job.VersionEnv,
		job.Case.RunnerUser,
	)
	fmt.Fprintf(a.Out, "Resolved images:\n%s\n", job.Images)

	// Compose owns containers, networks and volumes on the host, so teardown is
	// registered before anything can create them and runs on every in-process
	// exit path — success, setup or run failure, a canceled run, and panic
	// unwinding. Its own context is why a canceled caller still tears down
	// instead of leaving a project behind for the next invocation to collide with.
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		cleanupErr := a.run(cleanupCtx, a.Root, env, "docker", append(compose, "down", "-v", "--remove-orphans")...)
		if cleanupErr == nil {
			return
		}
		a.capturePackTestEvidence(cleanupCtx, compose, env, job.Plan.Services)
		err = errors.Join(err, fmt.Errorf("cleanup: %w", cleanupErr))
	}()

	setupArgs := append(append(compose, "up", "-d", "--wait"), job.Plan.Services...)
	setupErr := a.run(ctx, a.Root, env, "docker", setupArgs...)
	var runErr error
	if setupErr == nil {
		runArgs := append(compose, "run", "--rm", "--no-deps", "--entrypoint", "/opt/emisar/bin/packtest",
			"runner-tools", "--pack", job.Plan.Name, "--case", job.Case.ID, "--reports", "/tmp/packtest-reports")
		runErr = a.run(ctx, a.Root, env, "docker", runArgs...)
	} else {
		runErr = fmt.Errorf("setup: %w", setupErr)
	}
	if runErr != nil {
		a.capturePackTestEvidence(ctx, compose, env, job.Plan.Services)
	}
	return runErr
}

func packTestComposeArgs(baseCompose, packCompose, extra string) []string {
	compose := []string{"compose", "-f", baseCompose, "-f", packCompose}
	if extra != "" {
		compose = append(compose, "-f", extra)
	}
	return compose
}

type hostilePackTestCompose struct {
	Services map[string]hostilePackTestService `yaml:"services"`
}

type hostilePackTestService struct {
	CPUs      string `yaml:"cpus"`
	MemLimit  string `yaml:"mem_limit"`
	PidsLimit int    `yaml:"pids_limit"`
}

func writePackTestHostileOverride(reports string, plan packtest.PlanRef) (string, error) {
	services := make(map[string]hostilePackTestService, len(plan.Services))
	for _, service := range plan.Services {
		services[service] = hostilePackTestService{CPUs: "1.0", MemLimit: "1536m", PidsLimit: 512}
	}
	data, err := yaml.Marshal(hostilePackTestCompose{Services: services})
	if err != nil {
		return "", err
	}
	path := filepath.Join(reports, plan.Name+"-hostile.compose.yaml")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	return path, nil
}

type packTestComposeFile struct {
	Services map[string]packTestComposeService `yaml:"services"`
}

type packTestComposeService struct {
	Image string               `yaml:"image"`
	Build packTestComposeBuild `yaml:"build"`
}

type packTestComposeBuild struct {
	Context string            `yaml:"context"`
	Args    map[string]string `yaml:"args"`
}

// packTestNeedsSharedTools reports whether any selected plan reaches the shared
// client image. Building it pulls eight server images to extract one binary from
// each, and a pack whose compose replaces runner-tools with a SUT-derived build
// never runs a byte of it. haproxy is the exception that keeps this a question
// rather than a rule: its Dockerfile starts FROM the shared image, named through
// a PACKTEST_RUNNER_IMAGE build arg.
func packTestNeedsSharedTools(plans []packtest.PlanRef) (bool, error) {
	for _, plan := range plans {
		data, err := os.ReadFile(filepath.Join(filepath.Dir(plan.Path), "compose.yaml"))
		if err != nil {
			// preparePackTestPlan reports a missing plan compose per pack, with
			// the name in the message. Assume the shared image is wanted so the
			// run reaches that error rather than failing here without a pack.
			return true, nil
		}
		var compose packTestComposeFile
		if err := yaml.Unmarshal(data, &compose); err != nil {
			return false, fmt.Errorf("parse %s compose: %w", plan.Name, err)
		}
		tools, declared := compose.Services["runner-tools"]
		if !declared || tools.Build.Context == "" {
			return true, nil
		}
		if _, derived := tools.Build.Args["PACKTEST_RUNNER_IMAGE"]; derived {
			return true, nil
		}
	}
	return false, nil
}

func packTestBuildServices(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var compose packTestComposeFile
	if err := yaml.Unmarshal(data, &compose); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	var services []string
	for name, service := range compose.Services {
		if service.Build.Context != "" {
			services = append(services, name)
		}
	}
	sort.Strings(services)
	return services, nil
}

func packTestComposeEnv(
	root string,
	invocationID string,
	runnerImage string,
	plan packtest.PlanRef,
	caseID string,
	versionEnv map[string]string,
	user string,
) map[string]string {
	if user == "" {
		user = "nonroot"
	}
	composeUser := "65532:65532"
	if user == "root" {
		composeUser = "0:0"
	}
	env := map[string]string{
		"COMPOSE_PROJECT_NAME":  packTestComposeProject(root, invocationID, plan.Name, caseID),
		"EMISAR_ROOT":           root,
		"PACKTEST_RUNNER_IMAGE": runnerImage,
		"PACKTEST_RUNNER_USER":  composeUser,
	}
	for key, value := range versionEnv {
		env[key] = value
	}
	return env
}

func (a *App) capturePackTestEvidence(ctx context.Context, compose []string, env map[string]string, services []string) {
	fmt.Fprintln(a.Out, "\n=== failure evidence ===")
	for _, command := range [][]string{
		append(append([]string{}, compose...), "ps", "--all", "--no-trunc", "--format", "json"),
		append(append(append([]string{}, compose...), "logs", "--no-color", "--timestamps"), services...),
	} {
		output, err := a.output(ctx, a.Root, env, "docker", command...)
		if err != nil {
			fmt.Fprintf(a.Out, "evidence command failed: docker %s: %v\n", strings.Join(command, " "), err)
			continue
		}
		copyOutput(a.Out, output)
		if len(output) > 0 && output[len(output)-1] != '\n' {
			fmt.Fprintln(a.Out)
		}
	}
	idArgs := append(append([]string{}, compose...), "ps", "--all", "--quiet")
	ids, err := a.output(ctx, a.Root, env, "docker", idArgs...)
	if err != nil {
		fmt.Fprintf(a.Out, "container id discovery failed: %v\n", err)
		return
	}
	fields := strings.Fields(string(ids))
	if len(fields) == 0 {
		return
	}
	inspectArgs := append([]string{"inspect"}, fields...)
	inspect, err := a.output(ctx, a.Root, env, "docker", inspectArgs...)
	if err != nil {
		fmt.Fprintf(a.Out, "docker inspect failed: %v\n", err)
		return
	}
	copyOutput(a.Out, inspect)
}

func validatePackTestVersionInput(path, primaryService, defaultVersion string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var compose packTestComposeFile
	if err := yaml.Unmarshal(data, &compose); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	service, ok := compose.Services[primaryService]
	if !ok {
		return fmt.Errorf("the Compose project has no primary SUT service %s", primaryService)
	}
	versionInput := service.Image
	digestInput := service.Image
	if service.Build.Args["PACKTEST_IMAGE"] != "" {
		versionInput = service.Build.Args["PACKTEST_IMAGE"]
		digestInput = service.Build.Args["PACKTEST_IMAGE"]
	} else if service.Build.Args["PACKTEST_VERSION"] != "" {
		versionInput = service.Build.Args["PACKTEST_VERSION"]
		digestInput = service.Build.Args["PACKTEST_DIGEST"]
	}
	if !strings.Contains(versionInput, "${PACKTEST_VERSION:-"+defaultVersion+"}") {
		return fmt.Errorf("primary SUT service %s must default PACKTEST_VERSION to %s", primaryService, defaultVersion)
	}
	if !strings.Contains(digestInput, "${PACKTEST_DIGEST") {
		return fmt.Errorf("primary SUT service %s must consume PACKTEST_DIGEST", primaryService)
	}
	return nil
}

func packTestVersionEnv(planCount int, lookup func(string) (string, bool)) (map[string]string, error) {
	version, versionSet := lookup("PACKTEST_VERSION")
	digest, digestSet := lookup("PACKTEST_DIGEST")
	version = strings.TrimSpace(version)
	digest = strings.TrimSpace(digest)
	if !versionSet || version == "" {
		if digestSet && digest != "" {
			return nil, fmt.Errorf("PACKTEST_DIGEST requires PACKTEST_VERSION")
		}
		return nil, nil
	}
	if planCount != 1 {
		return nil, fmt.Errorf("PACKTEST_VERSION requires exactly one selected pack")
	}
	if digest != "" && !validPackTestDigest(digest) {
		return nil, fmt.Errorf("PACKTEST_DIGEST must match @sha256:<64 lowercase hex characters>")
	}
	return map[string]string{
		"PACKTEST_VERSION": version,
		"PACKTEST_DIGEST":  digest,
	}, nil
}

func resolvedPackTestVersionEnv(plan packtest.PlanRef, requested map[string]string) map[string]string {
	if len(requested) == 0 {
		version := plan.DefaultVersion()
		return map[string]string{
			"PACKTEST_VERSION": version.Version,
			"PACKTEST_DIGEST":  version.Digest,
		}
	}
	resolved := map[string]string{
		"PACKTEST_VERSION": requested["PACKTEST_VERSION"],
		"PACKTEST_DIGEST":  requested["PACKTEST_DIGEST"],
	}
	if resolved["PACKTEST_DIGEST"] == "" {
		for _, version := range plan.Versions {
			if version.Version == resolved["PACKTEST_VERSION"] {
				resolved["PACKTEST_DIGEST"] = version.Digest
				break
			}
		}
	}
	return resolved
}

func validPackTestDigest(digest string) bool {
	const prefix = "@sha256:"
	if !strings.HasPrefix(digest, prefix) || len(digest) != len(prefix)+64 {
		return false
	}
	encoded := digest[len(prefix):]
	if encoded != strings.ToLower(encoded) {
		return false
	}
	_, err := hex.DecodeString(encoded)
	return err == nil
}

func packTestInvocationID(now time.Time, pid int) string {
	return fmt.Sprintf("%s-%d", now.UTC().Format("20060102T150405.000000000Z"), pid)
}

// packTestRunnerImage names the shared client image after the bytes that
// produce it. The Dockerfile COPYs nothing from its build context, so those
// bytes are the entire input: a run that already has the tag can reuse a ~2GB
// image instead of pulling eight servers to extract one binary from each, and
// changed content lands on a different tag rather than staling this one.
func packTestRunnerImage(root string) (string, error) {
	dockerfile, err := os.ReadFile(filepath.Join(root, "dev", "test-packs", "Dockerfile"))
	if err != nil {
		return "", err
	}
	hash := fmt.Sprintf("%x", sha256.Sum256(dockerfile))
	return "emisar-runner-tools:" + hash[:12], nil
}

func packTestComposeProject(root, invocationID, pack, caseID string) string {
	hash := fmt.Sprintf("%x", sha256sum(root+"\x00"+invocationID+"\x00"+pack+"\x00"+caseID))
	name := strings.Map(func(char rune) rune {
		if char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '-' || char == '_' {
			return char
		}
		return '-'
	}, strings.ToLower(pack))
	if len(name) > 24 {
		name = name[:24]
	}
	return "emisar-packtest-" + name + "-" + hash[:12]
}

func (a *App) hasImage(ctx context.Context, image string) bool {
	_, err := a.output(ctx, a.Root, nil, "docker", "image", "inspect", image)
	return err == nil
}

func (a *App) pack(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return usage("%s", packUsage)
	}
	action := args[0]
	if action == "mirrors" {
		if len(args) != 3 || args[1] != "--registry" || args[2] == "" {
			return usage("usage: ./run pack mirrors --registry <image-repository>")
		}
		rows, err := packtest.Mirrors(
			filepath.Join(a.Root, "packs"),
			filepath.Join(a.Root, "dev", "test-packs", "mirrors.yaml"),
			args[2],
		)
		if err != nil {
			return err
		}
		encoder := json.NewEncoder(a.Out)
		encoder.SetIndent("", "  ")
		return encoder.Encode(rows)
	}
	if action == "tools-image" {
		if len(args) > 2 {
			return usage("usage: ./run pack tools-image [<pack-name>]")
		}
		image, err := packTestRunnerImage(a.Root)
		if err != nil {
			return err
		}
		if len(args) == 2 {
			// Named, the question is whether this pack reaches the image at
			// all: a pack that ships its own client wants no part of it, and
			// printing nothing is what lets CI skip restoring 2GB it will not
			// run.
			plans, err := packtest.Discover(filepath.Join(a.Root, "packs"), "", args[1])
			if err != nil {
				return err
			}
			needed, err := packTestNeedsSharedTools(plans)
			if err != nil {
				return err
			}
			if !needed {
				return nil
			}
		}
		fmt.Fprintln(a.Out, image)
		return nil
	}
	if action == "hashes" {
		if len(args) > 2 || len(args) == 2 && args[1] != "--write" {
			return usage("usage: ./run pack hashes [--write]")
		}
		if err := a.buildPackTools(ctx); err != nil {
			return err
		}
		return packhash.Check(a.Root, filepath.Join(a.Root, "bin", "emisar"), len(args) == 2, a.Out)
	}
	if len(args) < 2 || !isDirectory(filepath.Join(a.Root, "packs", args[1])) {
		return usage("%s", packUsage)
	}
	name := args[1]
	if err := a.buildPackTools(ctx); err != nil {
		return err
	}
	switch action {
	case "check":
		if len(args) != 2 {
			return usage("usage: ./run pack check <pack-name>")
		}
		if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "emisar"), "pack", "validate", filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if err := validatePackHTTPFailures(filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if err := validatePackPipelineFailures(filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if err := validatePackJQFilters(filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if err := validatePackScriptSyntax(ctx, filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if name == "redis" || name == "cassandra" {
			return packhash.Check(a.Root, filepath.Join(a.Root, "bin", "emisar"), false, a.Out)
		}
		return nil
	case "sync":
		if len(args) != 3 || args[2] != "--fix" {
			return usage("catalog sync mutates artifacts; pass: ./run pack sync <pack-name> --fix")
		}
		return a.packSync(ctx, name)
	default:
		return usage("%s", packUsage)
	}
}

func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func composeProject(root string) string {
	hash := fmt.Sprintf("%x", sha256sum(root))
	return "emisar-signing-e2e-" + hash[:12]
}

func sha256sum(value string) []byte {
	hash := sha256.Sum256([]byte(value))
	return hash[:]
}
