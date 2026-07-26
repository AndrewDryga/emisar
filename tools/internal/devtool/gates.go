package devtool

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/packhash"
)

// Keep this in step with the version any workflow installs directly.
const staticcheckVersion = "honnef.co/go/tools/cmd/staticcheck@2026.1"

// emisar is a security product, so an advisory fails the gate. cowlib 2.18.0 is
// current with no upstream patch, and its affected response-header encoder is
// reachable only from the internal Prometheus listener, which emits fixed
// headers behind the GCP firewall. Keep the exact IDs visible until a fix lands.
const ignoredAdvisories = "GHSA-g2wm-735q-3f56,EEF-CVE-2026-43966"

const (
	checkUsage = `usage: ./run check <target>

  changed                    compile and check changed Portal source files
  portal                     compile, format-check, and run Credo
  staged                     validate staged migrations and source formatting
  infra-templates            render and validate production cloud-init
  pack-environment [repo] [environment]
                             verify the registry deployment environment
  packs                      validate every pack and cross-language hash golden
  agent-setup                validate manuals, skills, tasks, hooks, and Coop verbs
`
	testUsage = `usage: ./run test <target> [args]

  portal <mix-test-args...>  run focused, --stale, --failed, or listening Portal tests
  runner [go-test-args...]   run all runner tests, or pass focused go test arguments
  mcp [go-test-args...]      run all MCP tests, or pass focused go test arguments
  tools [go-test-args...]    run all tooling tests, or pass focused go test arguments
  packs [name-pattern]       run pack behavior plans against real services
  packs <name> --case <id>   run one isolated behavior case
  packs <name> --shard <i>/<n>
                             run one declared shard of a slow pack's cases
  packs --names a,b          run an exact set of pack behavior plans
  install <runner|mcp>       exercise a public installer in an isolated harness
`
	gateUsage = `usage: ./run gate <target> [--coverage FILE]

  portal                     compile, format, Credo, and clean-output tests
  runner                     format, verify, vet, tidy-check, and race-test runner
  mcp                        format, verify, vet, tidy-check, and race-test MCP
  packs                      validate packs, hashes, catalog, and focused Portal tests
  infra                      format, initialize, validate, lint, and test templates
  tooling                    gate the shared Go tooling, docs, shell, and agent setup
  all                        run tooling, runner, MCP, packs, infra, and Portal gates

--coverage is supported by runner, mcp, and tooling for CI artifact collection.
`
	packUsage = `usage: ./run pack <action> [args]

  check <name>               validate one pack without changing artifacts
  hashes [--write]           verify or refresh cross-language pack hash goldens
  sync <name> --fix          rebuild the catalog from the live registry history
  tools-image [<name>]       print the shared behavior client image tag, or
                             nothing when the named pack ships its own client

Use "./run test packs [name-pattern]" for pack-owned behavior cases and
"./run gate packs" for the complete pack Definition of Done.
`
)

func (a *App) help(args []string) error {
	if len(args) == 0 {
		a.usage()
		return nil
	}
	if len(args) != 1 {
		return usage("usage: ./run help [check|test|gate|pack|ops]")
	}
	switch args[0] {
	case "check":
		fmt.Fprint(a.Out, checkUsage)
	case "test":
		fmt.Fprint(a.Out, testUsage)
	case "gate":
		fmt.Fprint(a.Out, gateUsage)
	case "pack":
		fmt.Fprint(a.Out, packUsage)
	case "ops":
		return a.infraOps(context.Background(), []string{"--help"})
	default:
		return usage("usage: ./run help [check|test|gate|pack|ops]")
	}
	return nil
}

func (a *App) test(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return usage("%s", testUsage)
	}
	target, rest := args[0], args[1:]
	switch target {
	case "portal":
		if len(rest) == 0 {
			return usage("usage: ./run test portal <paths...|--stale|--failed>")
		}
		_, env, err := a.up(ctx)
		if err != nil {
			return err
		}
		return a.portalTests(ctx, env, rest)
	case "runner", "mcp", "tools":
		arguments := append([]string{"test"}, rest...)
		if len(rest) == 0 {
			arguments = append(arguments, "-race", "-count=1", "./...")
		}
		return a.run(ctx, filepath.Join(a.Root, target), nil, "go", arguments...)
	case "packs":
		if len(rest) == 2 && rest[0] == "--names" {
			names := strings.Split(rest[1], ",")
			for _, name := range names {
				if name == "" {
					return usage("usage: ./run test packs --names pack-a,pack-b")
				}
			}
			return a.packTest(ctx, "", names, "", "")
		}
		if len(rest) == 3 && rest[1] == "--case" && rest[0] != "" && rest[2] != "" {
			return a.packTest(ctx, rest[0], nil, rest[2], "")
		}
		if len(rest) == 3 && rest[1] == "--shard" && rest[0] != "" && rest[2] != "" {
			return a.packTest(ctx, rest[0], nil, "", rest[2])
		}
		if len(rest) > 1 {
			return usage("usage: ./run test packs [name-pattern] | ./run test packs <name> --case <id> | ./run test packs <name> --shard <i>/<n> | ./run test packs --names pack-a,pack-b")
		}
		pattern := ""
		if len(rest) == 1 {
			pattern = rest[0]
		}
		return a.packTest(ctx, pattern, nil, "", "")
	case "install":
		if len(rest) != 1 || rest[0] != "runner" && rest[0] != "mcp" {
			return usage("usage: ./run test install <runner|mcp>")
		}
		return a.run(ctx, a.Root, nil, "go", "run", "./tools/cmd/installtest", rest[0])
	default:
		return usage("%s", testUsage)
	}
}

func parseCoverage(args []string) (string, error) {
	if len(args) == 0 {
		return "", nil
	}
	if len(args) != 2 || args[0] != "--coverage" || strings.TrimSpace(args[1]) == "" {
		return "", usage("coverage must be passed as --coverage FILE")
	}
	return args[1], nil
}

func (a *App) goGate(ctx context.Context, module, coverage string) error {
	dir := filepath.Join(a.Root, module)
	unformatted, err := a.output(ctx, dir, nil, "gofmt", "-l", "-s", ".")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(unformatted)) != "" {
		return fmt.Errorf("%s Go files are not formatted:\n%s", module, unformatted)
	}
	for _, arguments := range [][]string{{"mod", "verify"}, {"vet", "./..."}} {
		if err := a.run(ctx, dir, nil, "go", arguments...); err != nil {
			return err
		}
	}
	// staticcheck belongs to the canonical gate, not a CI-only step: as a CI-only
	// step it let a green local gate ship a red job, which is how forty findings
	// accumulated unseen. Pinned so a new staticcheck release cannot fail an
	// unchanged tree; `go run` keeps it off the contributor's PATH.
	if err := a.run(ctx, dir, nil, "go", "run", staticcheckVersion, "./..."); err != nil {
		return fmt.Errorf("%s staticcheck findings: %w", module, err)
	}
	// -diff prints what tidy would change and exits non-zero instead of writing,
	// so a gate never mutates the tree it verifies and a read-only review box can
	// run it. It also judges tidiness directly, rather than inferring it from a
	// clean `git diff` that a pre-existing edit would have failed anyway.
	if err := a.run(ctx, dir, nil, "go", "mod", "tidy", "-diff"); err != nil {
		return fmt.Errorf("%s module files are not tidy: %w", module, err)
	}
	// -diff cannot create the file, so this now asserts the invariant itself: a
	// dependency would surface above as a go.sum the diff wants to add.
	if module == "mcp" {
		if _, err := os.Stat(filepath.Join(dir, "go.sum")); err == nil {
			return fmt.Errorf("mcp must remain stdlib-only; go.sum exists")
		} else if !os.IsNotExist(err) {
			return err
		}
	}
	testArgs := []string{"test", "-race", "-count=1"}
	if coverage != "" {
		testArgs = append(testArgs, "-coverprofile="+coverage)
	}
	return a.run(ctx, dir, nil, "go", append(testArgs, "./...")...)
}

func (a *App) portalGate(ctx context.Context) error {
	var env map[string]string
	if os.Getenv("CI") == "" {
		_, workspaceEnv, err := a.up(ctx)
		if err != nil {
			return err
		}
		env = workspaceEnv
	} else if os.Getenv("DATABASE_URL") == "" {
		return fmt.Errorf("CI portal gate requires DATABASE_URL")
	}
	// A box keeps deps outside the repo mount (MIX_DEPS_PATH), so a fresh cache
	// must self-heal before the first compile; --check-locked refuses to rewrite
	// mix.lock, keeping the gate read-only toward the tree it verifies. Warm,
	// this is a sub-second no-op.
	if err := a.run(ctx, a.Portal, env, "mix", "deps.get", "--check-locked"); err != nil {
		return err
	}
	for _, arguments := range [][]string{
		{"compile", "--warnings-as-errors"},
		{"format", "--check-formatted"},
		{"credo"},
		{"deps.audit", "--ignore-advisory-ids", ignoredAdvisories},
		{"sobelow", "--root", "apps/emisar_web", "--config"},
	} {
		if err := a.run(ctx, a.Portal, env, "mix", arguments...); err != nil {
			return err
		}
	}
	// Captured rather than streamed: the known cycle's report is noise until the
	// budget actually breaks.
	if report, err := a.output(ctx, filepath.Join(a.Portal, "apps", "emisar"), env, "mix", "xref.cycles"); err != nil {
		return fmt.Errorf("compile-cycle budget: %w\n%s", err, report)
	}
	return a.portalTestOutput(ctx, env)
}

func (a *App) portalTestEnv(ctx context.Context) (map[string]string, error) {
	if os.Getenv("CI") != "" {
		if os.Getenv("DATABASE_URL") == "" {
			return nil, fmt.Errorf("CI pack gate requires DATABASE_URL")
		}
		return map[string]string{"MIX_ENV": "test"}, nil
	}
	_, env, err := a.up(ctx)
	if err != nil {
		return nil, err
	}
	env["MIX_ENV"] = "test"
	return env, nil
}

func (a *App) validatePacks(ctx context.Context) error {
	if err := a.buildPackTools(ctx); err != nil {
		return err
	}
	manifests, err := filepath.Glob(filepath.Join(a.Root, "packs", "*", "pack.yaml"))
	if err != nil {
		return err
	}
	sort.Strings(manifests)
	if len(manifests) == 0 {
		return fmt.Errorf("no pack manifests found under packs/")
	}
	var failures []string
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		fmt.Fprintf(a.Out, "\n==> %s\n", filepath.Base(packDir))
		if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "emisar"), "pack", "validate", packDir); err != nil {
			failures = append(failures, filepath.Base(packDir))
		} else if err := validatePackHTTPFailures(packDir); err != nil {
			fmt.Fprintln(a.Err, err)
			failures = append(failures, filepath.Base(packDir))
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("pack validation failed: %s", strings.Join(failures, ", "))
	}
	if err := packhash.Check(a.Root, filepath.Join(a.Root, "bin", "emisar"), false, a.Out); err != nil {
		return err
	}
	return nil
}

func (a *App) packsGate(ctx context.Context) error {
	if err := a.validatePacks(ctx); err != nil {
		return err
	}
	output, err := os.MkdirTemp("", "emisar-pack-gate-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(output)
	committed := filepath.Join(a.Portal, "apps", "emisar", "priv", "packs", "catalog.json")
	if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "packctl"),
		"catalog", "build", "--packs", filepath.Join(a.Root, "packs"), "--out", output, "--previous", committed); err != nil {
		return err
	}
	generated, err := os.ReadFile(filepath.Join(output, "v1", "catalog.json"))
	if err != nil {
		return err
	}
	current, err := os.ReadFile(committed)
	if err != nil {
		return err
	}
	if !bytes.Equal(generated, current) {
		return fmt.Errorf("bundled pack catalog is stale; run ./run pack sync <changed-pack> --fix")
	}

	env, err := a.portalTestEnv(ctx)
	if err != nil {
		return err
	}
	// Same self-heal as portalGate: a dependency bump lands in mix.lock before
	// any host fetches it, and deps.compile cannot fetch — without this the
	// packs gate dies on the first lock bump when it runs before the portal
	// gate (exactly how `gate all` orders them).
	if err := a.run(ctx, a.Portal, env, "mix", "deps.get", "--check-locked"); err != nil {
		return err
	}
	if err := a.warmPortalTestDependencies(ctx, env); err != nil {
		return err
	}
	if err := a.ensurePortalTestDatabase(ctx, env); err != nil {
		return err
	}
	checks := []struct {
		label string
		dir   string
		args  []string
	}{
		{"pack baseline tests", filepath.Join(a.Portal, "apps", "emisar"), []string{"test", "test/emisar/catalog/pack_baseline_test.exs"}},
		{"pack registry tests", filepath.Join(a.Portal, "apps", "emisar_web"), []string{"test", "test/emisar_web/packs_registry/cache_test.exs", "test/emisar_web/packs_test.exs"}},
	}
	for _, check := range checks {
		if err := a.runCaptured(ctx, check.label, check.dir, env, "mix", check.args...); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) infraGate(ctx context.Context) error {
	dir := filepath.Join(a.Root, "infra")
	for _, command := range []struct {
		name string
		args []string
	}{
		{"terraform", []string{"fmt", "-check", "-recursive"}},
		{"terraform", []string{"init", "-backend=false", "-input=false"}},
		{"terraform", []string{"validate"}},
		{"tflint", nil},
	} {
		if err := a.run(ctx, dir, nil, command.name, command.args...); err != nil {
			return err
		}
	}
	return a.infraOps(ctx, []string{"validate-templates"})
}

func (a *App) gate(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return usage("%s", gateUsage)
	}
	target, rest := args[0], args[1:]
	coverage, err := parseCoverage(rest)
	if err != nil {
		return err
	}
	switch target {
	case "portal":
		if coverage != "" {
			return usage("usage: ./run gate portal")
		}
		return a.portalGate(ctx)
	case "runner", "mcp":
		return a.goGate(ctx, target, coverage)
	case "packs":
		if coverage != "" {
			return usage("usage: ./run gate packs")
		}
		return a.packsGate(ctx)
	case "infra":
		if coverage != "" {
			return usage("usage: ./run gate infra")
		}
		return a.infraGate(ctx)
	case "tooling":
		return a.toolingGate(ctx, coverage)
	case "all":
		if coverage != "" {
			return usage("usage: ./run gate all")
		}
		for _, target := range []string{"tooling", "runner", "mcp", "packs", "infra", "portal"} {
			fmt.Fprintf(a.Out, "\n==> gate %s\n", target)
			if err := a.gate(ctx, []string{target}); err != nil {
				return fmt.Errorf("%s gate failed: %w", target, err)
			}
		}
		return nil
	default:
		return usage("%s", gateUsage)
	}
}
