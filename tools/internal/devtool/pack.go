package devtool

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
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
	if err := a.run(ctx, filepath.Join(a.Portal, "apps", "emisar"), nil, "mix", "test", "test/emisar/catalog/pack_baseline_test.exs"); err != nil {
		return err
	}
	return a.run(ctx, filepath.Join(a.Portal, "apps", "emisar_web"), nil, "mix", "test", "test/emisar_web/packs_registry/cache_test.exs", "test/emisar_web/packs_test.exs")
}

func (a *App) packTest(ctx context.Context, pattern string, names []string) error {
	harness := filepath.Join(a.Root, "dev", "test-packs")
	plans, err := packtest.Discover(filepath.Join(a.Root, "packs"), pattern, names...)
	if err != nil {
		return err
	}
	requestedVersionEnv, err := packTestVersionEnv(len(plans), os.LookupEnv)
	if err != nil {
		return err
	}
	reports := filepath.Join(harness, "reports")
	if err := os.MkdirAll(reports, 0o755); err != nil {
		return err
	}
	bin := filepath.Join(harness, "bin")
	baseCompose := filepath.Join(harness, "compose.yaml")
	preflightErr := func() error {
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
		composeEnv := map[string]string{"EMISAR_ROOT": a.Root}
		return a.run(ctx, a.Root, composeEnv, "docker", "compose", "-f", baseCompose, "build", "runner-tools")
	}()
	if preflightErr != nil {
		return errors.Join(preflightErr, writePackTestFailureReports(reports, plans, requestedVersionEnv, preflightErr))
	}

	jobs := make(chan packtest.PlanRef, len(plans))
	results := make(chan packTestResult, len(plans))
	for _, plan := range plans {
		jobs <- plan
	}
	close(jobs)

	workerCount := min(4, len(plans))
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for range workerCount {
		go func() {
			defer workers.Done()
			for plan := range jobs {
				var output bytes.Buffer
				versionEnv := resolvedPackTestVersionEnv(plan, requestedVersionEnv)
				writePackTestReportHeader(&output, plan, versionEnv)
				worker := New(a.Root, nil, &output, &output)
				runErr := worker.runPackTestProject(ctx, baseCompose, plan, versionEnv)
				if runErr != nil {
					fmt.Fprintf(&output, "\nError: %v\n", runErr)
				}
				results <- packTestResult{Plan: plan, Output: output.Bytes(), Err: runErr}
			}
		}()
	}
	go func() {
		workers.Wait()
		close(results)
	}()

	completed := make([]packTestResult, 0, len(plans))
	for result := range results {
		reportPath := filepath.Join(reports, result.Plan.Name+".log")
		if err := os.WriteFile(reportPath, result.Output, 0o644); err != nil {
			result.Err = errors.Join(result.Err, fmt.Errorf("write report: %w", err))
		}
		completed = append(completed, result)
		status := "PASS"
		if result.Err != nil {
			status = "FAIL"
		}
		fmt.Fprintf(a.Out, "[%d/%d] %s %s\n", len(completed), len(plans), status, result.Plan.Name)
	}
	sort.Slice(completed, func(i, j int) bool {
		return completed[i].Plan.Name < completed[j].Plan.Name
	})

	var failures []error
	for _, result := range completed {
		fmt.Fprintf(a.Out, "\n--- %s ---\n", result.Plan.Name)
		copyOutput(a.Out, result.Output)
		if result.Err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", result.Plan.Name, result.Err))
		}
	}
	return errors.Join(failures...)
}

func writePackTestFailureReports(dir string, plans []packtest.PlanRef, requested map[string]string, failure error) error {
	var failures []error
	for _, plan := range plans {
		var report bytes.Buffer
		versionEnv := resolvedPackTestVersionEnv(plan, requested)
		writePackTestReportHeader(&report, plan, versionEnv)
		fmt.Fprintf(&report, "Error: preflight: %v\n", failure)
		if err := os.WriteFile(filepath.Join(dir, plan.Name+".log"), report.Bytes(), 0o644); err != nil {
			failures = append(failures, fmt.Errorf("write %s report: %w", plan.Name, err))
		}
	}
	return errors.Join(failures...)
}

func writePackTestReportHeader(output io.Writer, plan packtest.PlanRef, versionEnv map[string]string) {
	fmt.Fprintf(output, "Pack: %s\nSUT version: %s\nSUT digest: %s\n\n",
		plan.Name, versionEnv["PACKTEST_VERSION"], versionEnv["PACKTEST_DIGEST"])
}

type packTestResult struct {
	Plan   packtest.PlanRef
	Output []byte
	Err    error
}

func (a *App) runPackTestProject(ctx context.Context, baseCompose string, plan packtest.PlanRef, versionEnv map[string]string) error {
	packCompose := filepath.Join(filepath.Dir(plan.Path), "compose.yaml")
	if !isFile(packCompose) {
		return fmt.Errorf("behavior plan has no sibling compose.yaml")
	}
	if len(plan.Services) == 0 {
		return fmt.Errorf("behavior plan has no primary SUT service")
	}
	defaultVersion := plan.DefaultVersion()
	if err := validatePackTestVersionInput(packCompose, plan.Services[0], defaultVersion.Version); err != nil {
		return err
	}
	compose := []string{"compose", "-f", baseCompose, "-f", packCompose}
	env := map[string]string{
		"COMPOSE_PROJECT_NAME": packTestComposeProject(a.Root, plan.Name),
		"EMISAR_ROOT":          a.Root,
	}
	for key, value := range versionEnv {
		env[key] = value
	}

	output, err := a.output(ctx, a.Root, env, "docker", append(compose, "config", "--services")...)
	if err != nil {
		return err
	}
	available := make(map[string]bool)
	for _, service := range strings.Fields(string(output)) {
		available[service] = true
	}
	if !available["runner-tools"] {
		return fmt.Errorf("Compose project has no runner-tools service")
	}
	for _, service := range plan.Services {
		if !available[service] {
			return fmt.Errorf("requires unknown Compose service %s", service)
		}
	}

	if isFile(filepath.Join(filepath.Dir(plan.Path), "Dockerfile")) {
		if err := a.run(ctx, a.Root, env, "docker", append(compose, "build", "runner-tools")...); err != nil {
			return fmt.Errorf("build pack runner tools: %w", err)
		}
	}
	setupArgs := append(append(compose, "up", "-d", "--wait", "--build"), plan.Services...)
	setupErr := a.run(ctx, a.Root, env, "docker", setupArgs...)
	var runErr error
	if setupErr == nil {
		runArgs := append(compose, "run", "--rm", "--no-deps", "--entrypoint", "/opt/emisar/bin/packtest", "runner-tools", "--pack", plan.Name)
		runErr = a.run(ctx, a.Root, env, "docker", runArgs...)
	} else {
		runErr = fmt.Errorf("setup: %w", setupErr)
	}

	cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cleanupErr := a.run(cleanupCtx, a.Root, env, "docker", append(compose, "down", "-v", "--remove-orphans")...)
	if cleanupErr != nil {
		cleanupErr = fmt.Errorf("cleanup: %w", cleanupErr)
	}
	return errors.Join(runErr, cleanupErr)
}

type packTestComposeFile struct {
	Services map[string]packTestComposeService `yaml:"services"`
}

type packTestComposeService struct {
	Image string               `yaml:"image"`
	Build packTestComposeBuild `yaml:"build"`
}

type packTestComposeBuild struct {
	Args map[string]string `yaml:"args"`
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
		return fmt.Errorf("Compose project has no primary SUT service %s", primaryService)
	}
	versionInput := service.Image
	digestInput := service.Image
	if service.Build.Args["PACKTEST_VERSION"] != "" {
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

func packTestComposeProject(root, pack string) string {
	hash := fmt.Sprintf("%x", sha256sum(root+"\x00"+pack))
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

func (a *App) pack(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return usage("%s", packUsage)
	}
	action := args[0]
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
