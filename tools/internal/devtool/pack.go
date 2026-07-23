package devtool

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/packhash"
	"github.com/andrewdryga/emisar/tools/internal/packtest"
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
	bin := filepath.Join(a.Root, "dev", "test-packs", "bin")
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
	if err := os.MkdirAll(filepath.Join(a.Root, "dev", "test-packs", "reports"), 0o755); err != nil {
		return err
	}
	compose := []string{"compose", "-f", "dev/test-packs/docker-compose.yaml"}
	composeEnv := map[string]string{"COMPOSE_PROJECT_NAME": packTestComposeProject(a.Root)}
	defer func() {
		_ = a.run(context.Background(), a.Root, composeEnv, "docker", append(compose, "down", "-v", "--remove-orphans")...)
	}()
	services, err := a.packTestServices(ctx, compose, pattern, names)
	if err != nil {
		return err
	}
	runnerService := "runner-tools"
	if err := a.run(ctx, a.Root, composeEnv, "docker", append(compose, "build", runnerService)...); err != nil {
		return err
	}
	if len(services) > 0 {
		arguments := append(append(compose, "up", "-d", "--wait"), services...)
		if err := a.run(ctx, a.Root, composeEnv, "docker", arguments...); err != nil {
			return err
		}
	}
	arguments := append(compose, "run", "--rm", "--entrypoint", "/opt/emisar/bin/packtest", runnerService)
	if pattern != "" {
		arguments = append(arguments, "--pattern", pattern)
	}
	for _, name := range names {
		arguments = append(arguments, "--pack", name)
	}
	return a.run(ctx, a.Root, composeEnv, "docker", arguments...)
}

func (a *App) packTestServices(ctx context.Context, compose []string, pattern string, names []string) ([]string, error) {
	plans, err := packtest.Discover(filepath.Join(a.Root, "packs"), pattern, names...)
	if err != nil {
		return nil, err
	}
	output, err := a.output(ctx, a.Root, nil, "docker", append(compose, "config", "--services")...)
	if err != nil {
		return nil, err
	}
	available := make(map[string]bool)
	for _, service := range strings.Fields(string(output)) {
		available[service] = true
	}
	return selectPlanServices(plans, available)
}

func selectPlanServices(plans []packtest.PlanRef, available map[string]bool) ([]string, error) {
	selected := make(map[string]bool)
	for _, plan := range plans {
		for _, service := range plan.Services {
			if !available[service] {
				return nil, fmt.Errorf("pack %s requires unknown Compose service %s", plan.Name, service)
			}
			selected[service] = true
		}
	}
	services := make([]string, 0, len(selected))
	for service := range selected {
		services = append(services, service)
	}
	sort.Strings(services)
	return services, nil
}

func packTestComposeProject(root string) string {
	hash := fmt.Sprintf("%x", sha256sum(root))
	return "emisar-packtest-" + hash[:12]
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

func composeProject(root string) string {
	hash := fmt.Sprintf("%x", sha256sum(root))
	return "emisar-signing-e2e-" + hash[:12]
}

func sha256sum(value string) []byte {
	hash := sha256.Sum256([]byte(value))
	return hash[:]
}
