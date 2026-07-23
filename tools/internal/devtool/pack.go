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

func (a *App) packTest(ctx context.Context, pattern string) error {
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
	services, packs, err := a.packTestServices(ctx, compose, pattern)
	if err != nil {
		return err
	}
	runnerService := "runner-tools"
	if len(packs) == 1 && packs[0] == "redis" {
		runnerService = "runner-tools-redis"
	}
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
	return a.run(ctx, a.Root, composeEnv, "docker", arguments...)
}

var packServiceAliases = map[string][]string{
	"aws-cloudwatch": {"localstack"}, "aws-cost": {"localstack"}, "aws-ec2": {"localstack"},
	"aws-iam": {"localstack"}, "aws-rds": {"localstack"}, "aws-s3": {"localstack"},
	"kubernetes": {"k3s", "k3s-kubeconfig"},
	"snmp":       {"snmpd", "snmpd-frr"},
}

func (a *App) packTestServices(ctx context.Context, compose []string, pattern string) ([]string, []string, error) {
	paths, err := filepath.Glob(filepath.Join(a.Root, "packs", "*", "test", "cases.json"))
	if err != nil {
		return nil, nil, err
	}
	var packs []string
	for _, path := range paths {
		name := filepath.Base(filepath.Dir(filepath.Dir(path)))
		if pattern == "" || strings.Contains(name, pattern) {
			packs = append(packs, name)
		}
	}
	if len(packs) == 0 {
		return nil, nil, fmt.Errorf("no pack cases matched %q", pattern)
	}
	output, err := a.output(ctx, a.Root, nil, "docker", append(compose, "config", "--services")...)
	if err != nil {
		return nil, nil, err
	}
	available := make(map[string]bool)
	for _, service := range strings.Fields(string(output)) {
		available[service] = true
	}
	services := selectPackServices(packs, available)
	sort.Strings(packs)
	return services, packs, nil
}

func selectPackServices(packs []string, available map[string]bool) []string {
	selected := make(map[string]bool)
	for _, pack := range packs {
		if available[pack] {
			selected[pack] = true
		}
		for _, service := range packServiceAliases[pack] {
			selected[service] = true
		}
	}
	services := make([]string, 0, len(selected))
	for service := range selected {
		services = append(services, service)
	}
	sort.Strings(services)
	return services
}

func packTestComposeProject(root string) string {
	hash := fmt.Sprintf("%x", sha256sum(root))
	return "emisar-packtest-" + hash[:12]
}

func (a *App) pack(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return usage("usage: dev/run pack <check|sync|test> [pack-name] [--fix]")
	}
	action := args[0]
	if action == "test" {
		if len(args) > 2 {
			return usage("usage: dev/run pack test [pack-name-pattern]")
		}
		pattern := ""
		if len(args) == 2 {
			pattern = args[1]
		}
		return a.packTest(ctx, pattern)
	}
	if len(args) < 2 || !isDirectory(filepath.Join(a.Root, "packs", args[1])) {
		return usage("usage: dev/run pack <check|sync> <pack-name> [--fix]")
	}
	name := args[1]
	if err := a.buildPackTools(ctx); err != nil {
		return err
	}
	switch action {
	case "check":
		if len(args) != 2 {
			return usage("usage: dev/run pack check <pack-name>")
		}
		if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "emisar"), "pack", "validate", filepath.Join(a.Root, "packs", name)); err != nil {
			return err
		}
		if name == "redis" || name == "cassandra" {
			return a.run(ctx, a.Root, map[string]string{"EMISAR_BIN": "bin/emisar"}, "bash", "packs/.agent/scripts/check-hash-golden.sh")
		}
		return nil
	case "sync":
		if len(args) != 3 || args[2] != "--fix" {
			return usage("catalog sync mutates artifacts; pass: dev/run pack sync <pack-name> --fix")
		}
		return a.packSync(ctx, name)
	default:
		return usage("usage: dev/run pack <check|sync|test> [pack-name] [--fix]")
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
