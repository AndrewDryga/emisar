package devtool

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/ci"
	"github.com/andrewdryga/emisar/tools/internal/hostaccess"
	"github.com/andrewdryga/emisar/tools/internal/packhash"
	"github.com/andrewdryga/emisar/tools/internal/packtest"
)

func elapsedLabel(started time.Time) string {
	elapsed := time.Since(started).Round(time.Millisecond)
	if elapsed == 0 {
		return "<1ms"
	}
	return elapsed.String()
}

func (a *App) gatePhase(label string, action func() error) error {
	fmt.Fprintf(a.Out, "\n==> %s\n", label)
	started := time.Now()
	if err := action(); err != nil {
		duration := elapsedLabel(started)
		fmt.Fprintf(a.Err, "<== FAIL %s (%s)\n", label, duration)
		return fmt.Errorf("phase %q failed after %s: %w", label, duration, err)
	}
	fmt.Fprintf(a.Out, "<== PASS %s (%s)\n", label, elapsedLabel(started))
	return nil
}

// Keep this in step with the version any workflow installs directly.
const staticcheckVersion = "honnef.co/go/tools/cmd/staticcheck@2026.1"

// Keep this in step with the version any workflow installs directly.
const actionlintVersion = "github.com/rhysd/actionlint/cmd/actionlint@v1.7.12"

// GitHub's $/ self-repository action reference is newer than the latest
// actionlint release. Keep the exception exact and restricted to the two
// trusted workflows; release-pin verification separately requires this form.
const actionlintSelfReferenceFalsePositive = `^specifying action "\$/\.github/actions/verify-release-tag" in invalid format because ref is missing\.`

var trustedReleaseWorkflowNames = map[string]bool{
	"mcp-release-trusted.yml":    true,
	"runner-release-trusted.yml": true,
}

// The platforms each module publishes. Keep this in step with the release
// workflows: a target that ships without compiling here is a broken release.
// The runner remains Unix-only; the Windows targets are the local MCP bridge
// beside a Windows LLM client, not the on-host action runner.
var releaseTargets = map[string][]string{
	"runner": {"linux/amd64", "linux/arm64", "darwin/amd64", "darwin/arm64"},
	"mcp":    {"linux/amd64", "linux/arm64", "darwin/amd64", "darwin/arm64", "windows/amd64", "windows/arm64"},
}

const (
	checkUsage = `usage: ./run check <target>

  changed                    compile and check changed Portal source files
  portal                     compile, format-check, and run Credo
  staged                     validate staged migrations and source formatting
  infra-templates            render and validate production cloud-init
  packs                      validate every pack and cross-language hash golden
  agent-setup                validate manuals, skills, tasks, hooks, and Coop verbs
  deps [--base <git ref>]    enforce dependency release age and source policy
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
  packs [name] --hostile    add one-CPU, 1536-MiB, and PID limits per SUT
  packs --names a,b          run an exact set of pack behavior plans
  pack-access [names...]     prove exact host-access recipes on systemd hosts
  install <runner|mcp>       exercise a public installer in an isolated harness
`
	gateUsage = `usage: ./run gate <target> [--coverage FILE]

  portal                     compile, format, Credo, audits, Sobelow, and tests
  runner                     format, boundaries, vet, staticcheck, tidy, attest
                             parity, race tests, cross-build, and the installer
  mcp                        the runner phases, plus the stdlib-only assertion
  packs                      validate packs, hashes, catalog, and focused Portal tests
  infra                      format, initialize, validate, lint, and test templates
  tooling                    the Go tooling phases, plus docs, workflow lint,
                             agent setup, dependency age, and shell scripts
  review                     run canonical gates selected from Coop's pinned review base
  all                        run tooling, runner, MCP, packs, infra, and Portal gates

--coverage is supported by runner, mcp, and tooling for CI artifact collection.
`
	packUsage = `usage: ./run pack <action> [args]

  check <name>               validate one pack without changing artifacts
  hashes [--write]           verify or refresh cross-language pack hash goldens
  mirrors --registry <repo>  print exact source-to-CI-mirror rows as JSON
  sync <name> --fix          rebuild the catalog from the live registry history
  tools-image [<name>]       print the shared behavior client image tag, or
                             nothing when the named pack ships its own client

Both are required before committing a pack change: "./run gate packs" validates
authoring, hashes, and the catalog, and "./run test packs [name-pattern]" runs
the behavior cases that actually execute an action. The gate alone has shipped
two regressions — it never runs a pack script.
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
			if goRaceSupported(runtime.GOOS, runtime.GOARCH) {
				arguments = append(arguments, "-race")
			}
			arguments = append(arguments, "-count=1", "./...")
		}
		return a.run(ctx, filepath.Join(a.Root, target), nil, "go", arguments...)
	case "packs":
		clean, hostile, err := packTestMode(rest)
		if err != nil {
			return err
		}
		rest = clean
		if len(rest) == 2 && rest[0] == "--names" {
			names := strings.Split(rest[1], ",")
			for _, name := range names {
				if name == "" {
					return usage("usage: ./run test packs --names pack-a,pack-b")
				}
			}
			return a.packTest(ctx, "", names, "", "", hostile)
		}
		if len(rest) == 3 && rest[1] == "--case" && rest[0] != "" && rest[2] != "" {
			return a.packTest(ctx, rest[0], nil, rest[2], "", hostile)
		}
		if len(rest) == 3 && rest[1] == "--shard" && rest[0] != "" && rest[2] != "" {
			return a.packTest(ctx, rest[0], nil, "", rest[2], hostile)
		}
		if len(rest) > 1 {
			return usage("usage: ./run test packs [name-pattern] | ./run test packs <name> --case <id> | ./run test packs <name> --shard <i>/<n> | ./run test packs --names pack-a,pack-b")
		}
		pattern := ""
		if len(rest) == 1 {
			pattern = rest[0]
		}
		return a.packTest(ctx, pattern, nil, "", "", hostile)
	case "pack-access":
		rows, err := hostaccess.Discover(filepath.Join(a.Root, "packs"), rest...)
		if err != nil {
			return err
		}
		return hostaccess.Run(ctx, a.Root, rows, a.Out)
	case "install":
		if len(rest) != 1 || rest[0] != "runner" && rest[0] != "mcp" {
			return usage("usage: ./run test install <runner|mcp>")
		}
		return a.run(ctx, a.Root, nil, "go", "run", "./tools/cmd/installtest", rest[0])
	default:
		return usage("%s", testUsage)
	}
}

func packTestMode(args []string) ([]string, bool, error) {
	clean := make([]string, 0, len(args))
	hostile := false
	for _, argument := range args {
		if argument != "--hostile" {
			clean = append(clean, argument)
			continue
		}
		if hostile {
			return nil, false, usage("--hostile may be passed only once")
		}
		hostile = true
	}
	return clean, hostile, nil
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

// checkClientModuleBoundaries keeps repo tooling out of the modules customers
// build and audit themselves. runner/ and mcp/ ship to self-hosters; packctl is
// the one sanctioned binary under runner/cmd (pack-hash parity, runner/AGENTS.md).
// Extending either list is a deliberate, reviewed act, so the gate decides it —
// as a CI-only step it was invisible until someone pushed.
func (a *App) checkClientModuleBoundaries(module string) error {
	if module == "tools" {
		return nil
	}
	entries, err := os.ReadDir(filepath.Join(a.Root, "runner", "cmd"))
	if err != nil {
		return err
	}
	var commands []string
	for _, entry := range entries {
		commands = append(commands, entry.Name())
	}
	if len(commands) != 1 || commands[0] != "packctl" {
		return fmt.Errorf(
			"runner/cmd must contain exactly packctl, found %v — repo tooling goes in tools/ (runner/AGENTS.md)",
			commands)
	}
	if _, err := os.Stat(filepath.Join(a.Root, "mcp", "cmd")); err == nil {
		return fmt.Errorf("mcp/ is client-shipped and carries no cmd/ — repo tooling goes in tools/ (runner/AGENTS.md)")
	} else if !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (a *App) goGate(ctx context.Context, module, coverage string) error {
	dir := filepath.Join(a.Root, module)
	if err := a.gatePhase(module+" source layout and format", func() error {
		if err := a.checkClientModuleBoundaries(module); err != nil {
			return err
		}
		unformatted, err := a.output(ctx, dir, nil, "gofmt", "-l", "-s", ".")
		if err != nil {
			return err
		}
		if strings.TrimSpace(string(unformatted)) != "" {
			return fmt.Errorf("%s Go files are not formatted:\n%s", module, unformatted)
		}
		return nil
	}); err != nil {
		return err
	}
	if err := a.gatePhase(module+" module verification", func() error {
		return a.run(ctx, dir, nil, "go", "mod", "verify")
	}); err != nil {
		return err
	}
	if err := a.gatePhase(module+" go vet", func() error {
		return a.run(ctx, dir, nil, "go", "vet", "./...")
	}); err != nil {
		return err
	}
	// staticcheck belongs to the canonical gate, not a CI-only step: as a CI-only
	// step it let a green local gate ship a red job, which is how forty findings
	// accumulated unseen. Pinned so a new staticcheck release cannot fail an
	// unchanged tree; `go run` keeps it off the contributor's PATH.
	if err := a.gatePhase(module+" staticcheck", func() error {
		if err := a.run(ctx, dir, nil, "go", "run", staticcheckVersion, "./..."); err != nil {
			return fmt.Errorf("%s staticcheck findings: %w", module, err)
		}
		return nil
	}); err != nil {
		return err
	}
	// -diff prints what tidy would change and exits non-zero instead of writing,
	// so a gate never mutates the tree it verifies and a read-only review box can
	// run it. It also judges tidiness directly, rather than inferring it from a
	// clean `git diff` that a pre-existing edit would have failed anyway.
	if err := a.gatePhase(module+" dependency integrity", func() error {
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
		// The runner and the bridge each carry their own copy of the attestation
		// verifier; drift between them is a security defect, so the gate decides it
		// rather than a CI step nobody sees until a push.
		if module == "runner" || module == "mcp" {
			if err := ci.CheckAttestParity(a.Root); err != nil {
				return fmt.Errorf("%s attestation parity: %w", module, err)
			}
		}
		return nil
	}); err != nil {
		return err
	}
	testArgs := []string{"test"}
	testLabel := module + " tests"
	if goRaceSupported(runtime.GOOS, runtime.GOARCH) {
		testArgs = append(testArgs, "-race")
		testLabel = module + " race tests"
	}
	testArgs = append(testArgs, "-count=1")
	if coverage != "" {
		testArgs = append(testArgs, "-coverprofile="+coverage)
	}
	if err := a.gatePhase(testLabel, func() error {
		return a.run(ctx, dir, nil, "go", append(testArgs, "./...")...)
	}); err != nil {
		return err
	}
	if module == "runner" || module == "mcp" {
		if err := a.crossBuildGate(ctx, module, dir); err != nil {
			return err
		}
		return a.installerGate(ctx, module)
	}
	return nil
}

func goRaceSupported(goos, goarch string) bool {
	// The Go toolchain has no race runtime for windows/arm64. Keep the native
	// tests and installer harness in the gate instead of failing before them.
	return goos != "windows" || goarch != "arm64"
}

// crossBuildGate proves every published target still compiles. It is pure
// CGO_ENABLED=0 cross-compilation, so a workstation can decide it — which is
// why it belongs here rather than in a CI step a green local gate cannot see.
// tools/ is never shipped, so it has no platform set to prove.
func (a *App) crossBuildGate(ctx context.Context, module, dir string) error {
	return a.gatePhase(module+" cross-platform build", func() error {
		for _, target := range releaseTargets[module] {
			goos, goarch, _ := strings.Cut(target, "/")
			env := map[string]string{"CGO_ENABLED": "0", "GOOS": goos, "GOARCH": goarch}
			if err := a.run(ctx, dir, env, "go", "build", "-trimpath", "-ldflags", "-s -w", "-o", os.DevNull, "."); err != nil {
				return fmt.Errorf("%s does not build for %s: %w", module, target, err)
			}
			fmt.Fprintf(a.Out, "ok: %s\n", target)
		}
		return nil
	})
}

func (a *App) installerGate(ctx context.Context, module string) error {
	if runtime.GOOS == "windows" {
		if module != "mcp" {
			return fmt.Errorf("the %s installer gate is not supported on Windows", module)
		}
		if err := a.gatePhase("mcp installer PowerShell", func() error {
			const parse = `$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:EMISAR_INSTALLER_SCRIPT, [ref]$tokens, [ref]$errors); if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }`
			return a.run(ctx, a.Root, map[string]string{
				"EMISAR_INSTALLER_SCRIPT": filepath.Join(a.Root, "install-mcp.ps1"),
			}, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", parse)
		}); err != nil {
			return err
		}
		return a.gatePhase("mcp installer behavior", func() error {
			return a.run(ctx, a.Root, nil, "go", "run", "./tools/cmd/installtest", "mcp-windows")
		})
	}

	script := "install.sh"
	if module == "mcp" {
		script = "install-mcp.sh"
	}
	if err := a.gatePhase(module+" installer shell", func() error {
		if err := a.run(ctx, a.Root, nil, "shellcheck", script); err != nil {
			return err
		}
		return a.run(ctx, a.Root, nil, "bash", "-n", script)
	}); err != nil {
		return err
	}
	return a.gatePhase(module+" installer behavior", func() error {
		return a.run(ctx, a.Root, nil, "go", "run", "./tools/cmd/installtest", module)
	})
}

func (a *App) portalGate(ctx context.Context) error {
	var env map[string]string
	if os.Getenv("CI") != "" && os.Getenv("DATABASE_URL") == "" {
		return fmt.Errorf("CI portal gate requires DATABASE_URL")
	}
	// Fetching a locked dependency graph and checking source format are the
	// cheapest deterministic failures. Run them before starting services or
	// compiling the umbrella so a bad candidate fails in seconds.
	if err := a.gatePhase("portal locked dependencies", func() error {
		return a.run(ctx, a.Portal, nil, "mix", "deps.get", "--check-locked")
	}); err != nil {
		return err
	}
	if err := a.gatePhase("portal format", func() error {
		return a.run(ctx, a.Portal, nil, "mix", "format", "--check-formatted")
	}); err != nil {
		return err
	}
	if os.Getenv("CI") == "" {
		if err := a.gatePhase("portal development services", func() error {
			_, workspaceEnv, upErr := a.up(ctx)
			env = workspaceEnv
			return upErr
		}); err != nil {
			return err
		}
	}
	// Compile under MIX_ENV=test so test/support is in the compile path with
	// --warnings-as-errors, exactly as CI (which sets MIX_ENV: test at the job
	// level) does. The local env from a.up() carries no MIX_ENV, so this phase
	// ran in :dev and skipped test/support entirely — a warning there passed a
	// green local gate and failed the identical CI phase.
	compileEnv := map[string]string{"MIX_ENV": "test"}
	for k, v := range env {
		compileEnv[k] = v
	}
	compileEnv["MIX_ENV"] = "test"
	if err := a.gatePhase("portal compile", func() error {
		return a.run(ctx, a.Portal, compileEnv, "mix", "compile", "--warnings-as-errors")
	}); err != nil {
		return err
	}
	for _, check := range []struct {
		label string
		args  []string
	}{
		{"portal Credo", []string{"credo"}},
		{"portal dependency audit", []string{"deps.audit"}},
		// A different class from deps.audit: only hex.audit reports a package the
		// MAINTAINER retired (yanked, deprecated, security-retired). Without it
		// nothing here would notice a portal dependency being pulled.
		{"portal retired dependencies", []string{"hex.audit"}},
		{"portal Sobelow", []string{"sobelow", "--root", "apps/emisar_web", "--config"}},
	} {
		if err := a.gatePhase(check.label, func() error {
			return a.run(ctx, a.Portal, env, "mix", check.args...)
		}); err != nil {
			return err
		}
	}
	// Captured rather than streamed: a healthy zero-cycle report is empty, so
	// surface xref output only when the budget breaks.
	if err := a.gatePhase("portal compile-cycle budget", func() error {
		report, err := a.output(ctx, filepath.Join(a.Portal, "apps", "emisar"), env, "mix", "xref.cycles")
		if err != nil {
			return fmt.Errorf("compile-cycle budget: %w\n%s", err, report)
		}
		return nil
	}); err != nil {
		return err
	}
	return a.gatePhase("portal test suites", func() error {
		return a.portalTestOutput(ctx, env)
	})
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
		} else if err := validatePackActionLints(ctx, packDir); err != nil {
			fmt.Fprintln(a.Err, err)
			failures = append(failures, filepath.Base(packDir))
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("pack validation failed: %s", strings.Join(failures, ", "))
	}
	plans, err := packtest.Discover(filepath.Join(a.Root, "packs"), "")
	if err != nil {
		return err
	}
	if err := packtest.Validate(plans); err != nil {
		return fmt.Errorf("pack behavior authoring: %w", err)
	}
	if _, err := hostaccess.Discover(filepath.Join(a.Root, "packs")); err != nil {
		return fmt.Errorf("pack host-access proof authoring: %w", err)
	}
	if _, err := packtest.Mirrors(
		filepath.Join(a.Root, "packs"),
		filepath.Join(a.Root, "dev", "test-packs", "mirrors.yaml"),
		"ghcr.io/emisar-dev/emisar-packtest-suts",
	); err != nil {
		return fmt.Errorf("pack behavior mirrors: %w", err)
	}
	if err := packhash.Check(a.Root, filepath.Join(a.Root, "bin", "emisar"), false, a.Out); err != nil {
		return err
	}
	return a.checkCatalogReproduction(ctx)
}

// checkCatalogReproduction proves the committed catalog artifact is what a
// fresh build produces. It lives in validatePacks — not only in the packs gate
// — because CI reaches packs through `./run check packs`, which needs no
// database. Left in the gate alone, a stale artifact passed CI green and failed
// in CD's deployment-plan step, AFTER packs-publish had already mutated the
// live registry.
func (a *App) checkCatalogReproduction(ctx context.Context) error {
	output, err := os.MkdirTemp("", "emisar-pack-catalog-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(output)
	committed := filepath.Join(a.Portal, "apps", "emisar", "priv", "packs", "catalog.json")
	if err := a.run(ctx, a.Root, nil, filepath.Join(a.Root, "bin", "packctl"),
		"catalog", "build", "--packs", filepath.Join(a.Root, "packs"), "--out", output, "--previous", committed); err != nil {
		return err
	}
	if err := checkPackRegistryPointerContract(a.Root, filepath.Join(output, "manifest.json")); err != nil {
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
	return nil
}

func (a *App) packsGate(ctx context.Context) error {
	if err := a.gatePhase("pack authoring, hashes, and catalog", func() error {
		return a.validatePacks(ctx)
	}); err != nil {
		return err
	}

	var env map[string]string
	if err := a.gatePhase("pack Portal test preparation", func() error {
		var prepareErr error
		env, prepareErr = a.portalTestEnv(ctx)
		if prepareErr != nil {
			return prepareErr
		}
		// Same self-heal as portalGate: a dependency bump lands in mix.lock before
		// any host fetches it, and deps.compile cannot fetch — without this the
		// packs gate dies on the first lock bump when it runs before the portal
		// gate (exactly how `gate all` orders them).
		if err := a.run(ctx, a.Portal, env, "mix", "deps.get", "--check-locked"); err != nil {
			return err
		}
		return a.warmPortalTestDependencies(ctx, env)
	}); err != nil {
		return err
	}
	// The migration's ACCESS EXCLUSIVE DDL cancels a concurrent portal run's
	// queries, and the lock dir is user-scoped so two checkouts share one
	// database. Take the lock after the warm-up (which touches no database) and
	// hold it across the migration and all three suites — the same window
	// portalTests protects. Without it, `gate packs` and `gate portal` in two
	// checkouts poisoned each other with query_canceled, and the failure named
	// whichever tests happened to be running.
	lock, err := a.portalTestLock(env)
	if err != nil {
		return err
	}
	defer releasePortalTestLock(lock)
	if err := a.gatePhase("pack test database", func() error {
		return a.ensurePortalTestDatabase(ctx, env)
	}); err != nil {
		return err
	}
	checks := []struct {
		label string
		dir   string
		args  []string
	}{
		{"pack baseline tests", filepath.Join(a.Portal, "apps", "emisar"), []string{"test", "test/emisar/catalog/pack_baseline_test.exs"}},
		{"pack registry tests", filepath.Join(a.Portal, "apps", "emisar"), []string{"test", "test/emisar/catalog/published_registry_test.exs", "test/emisar/catalog/published_registry/cache_test.exs"}},
		{"pack registry page tests", filepath.Join(a.Portal, "apps", "emisar_web"), []string{"test", "test/emisar_web/packs_test.exs"}},
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
	// A pure file read, so it fails in milliseconds before terraform or tflint is
	// invoked — and it belongs in the gate rather than only a CI step, so a green
	// local run cannot ship a .tool-versions that disagrees with the workflow pins.
	if err := a.gatePhase("infra toolchain pins", a.checkInfraToolchainPins); err != nil {
		return err
	}
	for _, command := range []struct {
		label string
		name  string
		args  []string
	}{
		{"infra Terraform format", "terraform", []string{"fmt", "-check", "-recursive"}},
		{"infra Terraform initialization", "terraform", []string{"init", "-backend=false", "-input=false"}},
		{"infra Terraform validation", "terraform", []string{"validate"}},
		{"infra TFLint", "tflint", nil},
	} {
		if err := a.gatePhase(command.label, func() error {
			return a.run(ctx, dir, nil, command.name, command.args...)
		}); err != nil {
			return err
		}
	}
	if err := a.gatePhase("infra rendered templates", func() error {
		return a.infraOps(ctx, []string{"validate-templates"})
	}); err != nil {
		return err
	}
	return a.gatePhase("infra trusted release pins", func() error {
		return a.infraOps(ctx, []string{"verify-release-pins"})
	})
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
	case "review":
		if coverage != "" {
			return usage("usage: ./run gate review")
		}
		return a.reviewGate(ctx)
	case "all":
		if coverage != "" {
			return usage("usage: ./run gate all")
		}
		for _, target := range []string{"tooling", "runner", "mcp", "packs", "infra", "portal"} {
			if err := a.gatePhase("complete "+target+" gate", func() error {
				return a.gate(ctx, []string{target})
			}); err != nil {
				return err
			}
		}
		return nil
	default:
		return usage("%s", gateUsage)
	}
}

func (a *App) reviewGate(ctx context.Context) error {
	baseRef := strings.TrimSpace(os.Getenv("COOP_REVIEW_BASE"))
	if baseRef == "" {
		baseRef = "refs/coop/session-parent"
	}
	base, err := a.output(ctx, a.Root, nil, "git", "rev-parse", "--verify", baseRef+"^{commit}")
	if err != nil {
		return fmt.Errorf("the Coop review base is unavailable: %w", err)
	}
	selection, err := ci.Select(ctx, a.Root, "pull_request", strings.TrimSpace(string(base)))
	if err != nil {
		return fmt.Errorf("select review gates: %w", err)
	}
	for _, target := range reviewGateTargets(selection) {
		if err := a.gatePhase("review "+target+" gate", func() error {
			return a.gate(ctx, []string{target})
		}); err != nil {
			return err
		}
	}
	return nil
}

func reviewGateTargets(selection ci.Selection) []string {
	var targets []string
	if selection.Tools {
		targets = append(targets, "tooling")
	}
	if selection.Runner {
		targets = append(targets, "runner")
	}
	if selection.MCP {
		targets = append(targets, "mcp")
	}
	if selection.Packs {
		targets = append(targets, "packs")
	}
	if selection.Infra {
		targets = append(targets, "infra")
	}
	if selection.Portal {
		targets = append(targets, "portal")
	}
	if len(targets) == 0 {
		targets = append(targets, "tooling")
	}
	return targets
}
