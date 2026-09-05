package ci

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/packtest"
	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

type Selection struct {
	Portal        bool
	Runner        bool
	MCP           bool
	Tools         bool
	Packs         bool
	Infra         bool
	Deps          bool
	Workflows     bool
	MCPListing    bool
	PortalRelease bool
	PacksRelease  bool
	RunnerImage   bool
	PackBehavior  []packtest.MatrixRow
	SigningE2E    bool
	SSOE2E        bool
}

func Select(ctx context.Context, root, event, base string) (Selection, error) {
	files := []string{"__run_all__"}
	if validBase(ctx, root, base) {
		from, err := diffBase(ctx, root, event, base)
		if err != nil {
			return Selection{}, err
		}
		data, err := git(ctx, root, "diff", "--no-renames", "--name-only", "-z", from, "HEAD")
		if err != nil {
			return Selection{}, err
		}
		files = toolutil.NULFields(data)
	}

	var selection Selection
	for _, file := range files {
		selection.include(file)
	}
	runnerImage, err := selectRunnerImage(root, files)
	if err != nil {
		return Selection{}, err
	}
	selection.RunnerImage = selection.RunnerImage || runnerImage
	if selection.Workflows {
		selection.Portal = true
		selection.Runner = true
		selection.MCP = true
		selection.Tools = true
		selection.Packs = true
		selection.Infra = true
		selection.Deps = true
		selection.MCPListing = true
		selection.RunnerImage = true
		selection.SigningE2E = true
		selection.SSOE2E = true
	}
	packBehavior, err := selectPackBehavior(root, files)
	if err != nil {
		return Selection{}, err
	}
	selection.PackBehavior = packBehavior
	if event == "push" {
		selection.Portal = true
		selection.PortalRelease = true
		if !selection.PacksRelease {
			reason, err := packsReleaseDrift(ctx, root)
			if err != nil {
				return Selection{}, err
			}
			if reason != "" {
				fmt.Printf("::notice::%s\n", reason)
				// Packs runs too: the stranded pack push may have failed CI, so
				// the sources about to be published may never have validated green.
				selection.Packs = true
				selection.PacksRelease = true
			}
		}
	}
	return selection, nil
}

func (selection *Selection) include(file string) {
	if file == "__run_all__" {
		*selection = Selection{
			Portal: true, Runner: true, MCP: true, Tools: true, Packs: true,
			Infra: true, Deps: true, Workflows: true, MCPListing: true,
			PortalRelease: true, PacksRelease: true, RunnerImage: true,
			SigningE2E: true, SSOE2E: true,
		}
		return
	}

	packFile := isPackFile(file)
	packRegistryPointerContract := file == "infra/pack_registry_mutable_pointers.json"
	packRuntimeSource := packFile && !isPackTestFile(file)
	goCheckoutContract := file == ".gitattributes"
	if strings.HasPrefix(file, "portal/") || slices.Contains([]string{".dockerignore", "install.sh", "install-mcp.sh", "install-mcp.ps1", ".tool-versions"}, file) {
		selection.Portal = true
		selection.PortalRelease = true
	}
	if file == ".trivyignore.yaml" {
		selection.Portal = true
	}
	if packRuntimeSource {
		selection.Portal = true
		selection.PortalRelease = true
	}
	// The pack/catalog schema is a cross-language contract: Go writes it, the
	// Portal reads it. Its Portal-side proof (pack_baseline, published_registry,
	// the packs page) lives in the Portal suite, so a Go-only schema change must
	// select Portal too — otherwise CI validates one half of a contract whose
	// halves can only break together.
	if toolutil.HasAnyPrefix(file, "runner/pkg/packspec/", "runner/pkg/actionspec/", "runner/internal/catalog/") {
		selection.Portal = true
		selection.PortalRelease = true
	}
	// dev/json-corpus is the golden both hostile-JSON validators must agree on;
	// the module boundary forbids sharing their code, so the corpus IS the
	// parity check and a change to it has to run both suites.
	jsonCorpus := strings.HasPrefix(file, "dev/json-corpus/")
	sharedInstallerHarness := toolutil.HasAnyPrefix(file, "tools/cmd/installtest/", "tools/internal/installtest/harness")
	runnerInstallerHarness := sharedInstallerHarness || strings.HasPrefix(file, "tools/internal/installtest/runner")
	mcpInstallerHarness := sharedInstallerHarness || strings.HasPrefix(file, "tools/internal/installtest/mcp")
	if strings.HasPrefix(file, "runner/") || jsonCorpus || runnerInstallerHarness || goCheckoutContract || slices.Contains([]string{"install.sh", "README.md", "go.work", "go.work.sum"}, file) {
		selection.Runner = true
	}
	if strings.HasPrefix(file, "mcp/") || jsonCorpus || mcpInstallerHarness || goCheckoutContract || slices.Contains([]string{"install-mcp.sh", "install-mcp.ps1", "go.work", "go.work.sum"}, file) {
		selection.MCP = true
	}
	// The public MCP Registry listing is a cross-language contract like the pack
	// schema above: the listing job validates it against the registry's own JSON
	// schema, while every emisar-specific assertion — the dev.emisar/emisar
	// namespace, the remote URL each LLM client dials, the description cap, and
	// agreement with portal/VERSION — lives in EmisarWeb.MCPRegistryTest. A
	// server.json-only edit used to select the one job that cannot check any of
	// them.
	if file == "server.json" {
		selection.MCPListing = true
		selection.Portal = true
		selection.PortalRelease = true
	}
	// .github/workflows and .githooks route here because actionlint and the
	// shell lint both live inside the TOOLING gate. Workflow changes previously
	// set only selection.Workflows, which no job consumes and ci-gate does not
	// require — so a workflow-only PR was linted by nothing while the CI summary
	// printed "Actions - Validate workflows | run". .githooks and .gitignore
	// selected no job at all, though agentcheck asserts the commit-msg hook and
	// the distribution ignore policy from inside that same gate.
	// .github/actions holds the release-authority composite (verify-release-tag);
	// its stale-pin drift check runs inside the tooling/infra gates, and actionlint
	// covers it there. Without this a composite-only change selected no job and
	// "Required - CI" went green having validated release control code with nothing.
	// dist/ carries the tracked Cursor/ChatGPT integration packages agentcheck
	// validates. docker-compose.yml + config.exs are the two sides of the tooling
	// gate's e2e-stack-version check; neither selected Tools before, so editing
	// either re-introduced the drift that check exists to catch.
	// The listed files mirror trackedShellFiles' pathspec (`.shell run *.sh
	// .githooks`): every file that gate shellchecks has to select the gate, or a
	// syntax error in the contributor shell profile ships green.
	// portal/Dockerfile is here because the tooling gate's release-toolchain
	// phase is what holds its ELIXIR/OTP/hex/rebar3 ARG defaults to .tool-versions
	// and the CI workflow's pins; a Dockerfile-only bump otherwise selected only
	// the Portal job, which cannot see that disagreement.
	if toolutil.HasAnyPrefix(file, "tools/", "dev/", ".agent/", ".claude/", ".codex/", ".gemini/", "skills/", "dist/", ".github/workflows/", ".github/actions/", ".githooks/") || strings.Contains(file, "/.agent/") || slices.Contains([]string{"run", ".shell", "go.work", "go.work.sum", ".gitattributes", ".gitignore", ".tool-versions", "docker-compose.yml", "portal/config/config.exs", "portal/Dockerfile"}, file) || filepath.Ext(file) == ".md" {
		selection.Tools = true
	}
	// Pack behavior plans are validation inputs but are not loaded into registry
	// artifacts. Every runtime input below deliberately matches PacksRelease:
	// validatePacks ends in checkCatalogReproduction, so code that BUILDS the
	// catalog must run the job that proves the committed catalog still reproduces.
	if packFile || packRegistryPointerContract || toolutil.HasAnyPrefix(file, "runner/internal/packs/", "runner/internal/catalog/", "runner/cmd/packctl/", "runner/pkg/packspec/", "runner/pkg/actionspec/") || slices.Contains([]string{"runner/pack.go", "runner/main.go", "runner/go.mod", "runner/go.sum", "go.work", "go.work.sum"}, file) {
		selection.Packs = true
	}
	if toolutil.HasAnyPrefix(file, "dev/test-host-access/", "tools/internal/hostaccess/") {
		selection.Packs = true
	}
	if packRuntimeSource || toolutil.HasAnyPrefix(file, "runner/internal/packs/", "runner/internal/catalog/", "runner/cmd/packctl/", "runner/pkg/packspec/", "runner/pkg/actionspec/") || slices.Contains([]string{"runner/pack.go", "runner/main.go", "runner/go.mod", "runner/go.sum", "go.work", "go.work.sum"}, file) {
		selection.PacksRelease = true
	}
	if strings.HasPrefix(file, "infra/") || file == ".tool-versions" {
		selection.Infra = true
	}
	if slices.Contains([]string{"portal/mix.lock", "runner/go.mod", "runner/go.sum", "mcp/go.mod", "mcp/go.sum", "tools/go.mod", "tools/go.sum", "tools/cmd/entra-capture/package-lock.json", ".dep-age-allow"}, file) || strings.HasPrefix(file, "tools/cmd/depgate/") {
		selection.Deps = true
	}
	// The selector is workflow control code: validate every branch it can route
	// whenever its implementation or command entrypoint changes.
	if toolutil.HasAnyPrefix(file, ".github/workflows/", ".github/actions/", "tools/cmd/ci/", "tools/internal/ci/") || file == ".github/dependabot.yml" {
		selection.Workflows = true
	}
	// Both halves of the signer↔verifier contract, because the e2e drives the
	// real bridge rather than a reimplementation. The bridge's signing seam is
	// mcp/sign.go plus the signer construction in mcp/main.go; there is no
	// mcp/internal/signing package, and naming one here meant a change to
	// attested dispatch on the bridge side skipped the required check entirely.
	// Both scenarios boot through the shared demo seeder before reaching their
	// own assertions, so a seed change is a behavior input to both.
	// The portal side enters by PREFIX, not by three named files: naming
	// runs.ex and runs/attestation.ex left their siblings selecting nothing —
	// runners.ex ingests the runner's enforce_signatures advertisement and is
	// what stops dispatching unsigned, and runs/action_run/changeset.ex is what
	// refuses an attestation that did not validate.
	sharedE2ESeed := file == "portal/apps/emisar/priv/repo/seeds.exs"
	if toolutil.HasAnyPrefix(
		file,
		"tools/cmd/signing-e2e/",
		"dev/signing/",
		"runner/internal/signing/",
		"runner/internal/attest/",
		"mcp/internal/attest/",
		"portal/apps/emisar/lib/emisar/runs",
		"portal/apps/emisar/lib/emisar/runners",
	) || sharedE2ESeed || slices.Contains([]string{
		"docker-compose.yml",
		"tools/internal/devtool/e2e.go",
		"mcp/sign.go",
		"mcp/main.go",
		"portal/apps/emisar_web/lib/emisar_web/controllers/mcp/action_tools.ex",
	}, file) {
		selection.SigningE2E = true
	}
	if toolutil.HasAnyPrefix(
		file,
		"tools/cmd/sso-e2e/",
		"dev/keycloak/",
		"portal/apps/emisar/lib/emisar/sso/",
		"portal/apps/emisar_web/lib/emisar_web/controllers/sso",
		"portal/apps/emisar_web/lib/emisar_web/controllers/oauth",
		"portal/apps/emisar_web/lib/emisar_web/controllers/scim/",
		"portal/apps/emisar_web/lib/emisar_web/live/sso",
	) || sharedE2ESeed || slices.Contains([]string{
		"docker-compose.yml",
		"tools/internal/devtool/e2e.go",
		"portal/apps/emisar/lib/emisar/sso.ex",
	}, file) {
		selection.SSOE2E = true
	}
}

// selectRunnerImage reports whether the official runner container image must
// be rebuilt and smoke-tested: its inputs are the runner source the CI job
// compiles into it (which also carries the CLI surface verify-image.sh
// drives), the shared filtered root context (.dockerignore), and the packs
// container-packs.txt bakes in — read from that file so the trigger list can
// never drift from the baked pack list.
func selectRunnerImage(root string, files []string) (bool, error) {
	packs, err := containerPacks(root)
	if err != nil {
		return false, err
	}
	for _, file := range files {
		if file == "__run_all__" || file == ".dockerignore" || strings.HasPrefix(file, "runner/") {
			return true, nil
		}
		for _, pack := range packs {
			if strings.HasPrefix(file, "packs/"+pack+"/") {
				return true, nil
			}
		}
	}
	return false, nil
}

// containerPacks reads the image's baked pack list. A repository without the
// list (test fixtures) simply has no container image to select.
func containerPacks(root string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(root, "runner", "release", "container-packs.txt"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var packs []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		packs = append(packs, line)
	}
	return packs, nil
}

// publishedCatalogURL is the canonical serving endpoint the CD packs-publish
// and deployment-plan jobs verify against; a variable so tests can probe a
// local server instead of the live registry.
var publishedCatalogURL = "https://registry.emisar.dev/v1/catalog.json"

// packsReleaseDrift reports why a main push must publish the pack registry
// even though its diff touches no pack source. The diff trigger alone is
// edge-triggered: when a pack-changing push's CD run fails, is cancelled, or
// loses its approval race, no later push carries the pack diff to retry, and
// the registry silently serves a stale catalog (12 packs stranded this way
// between 2026-07-29 and 2026-07-31). Comparing the live catalog against the
// committed one — which the packs gate keeps byte-equal to a fresh build —
// makes publication level-triggered on registry state instead. An empty
// reason means the registry already serves the committed bytes. An unreadable
// registry is a reason to publish: a missing or malformed catalog pointer is
// repaired by the publication itself, while a broken serving domain (DNS,
// TLS, load balancer) still fails the publish job's own preflight explicitly
// rather than CD silently skipping. A repository
// without the committed catalog (test fixtures) has no registry to reconcile.
func packsReleaseDrift(ctx context.Context, root string) (string, error) {
	committed, err := os.ReadFile(filepath.Join(root, "portal", "apps", "emisar", "priv", "packs", "catalog.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	live, err := fetchPublishedCatalog(ctx, int64(len(committed))+1)
	if err != nil {
		return fmt.Sprintf("Publishing the pack registry: the live catalog is unreadable (%v)", err), nil
	}
	if !bytes.Equal(live, committed) {
		return "Publishing the pack registry: the live catalog does not match the committed catalog", nil
	}
	return "", nil
}

// fetchPublishedCatalog reads the live catalog pointer for the equality check.
// Reading one byte past the committed length is enough to prove inequality
// while bounding hostile input. Redirects are refused, matching the workflows'
// plain curl: the canonical endpoint serves directly, and treating a redirect
// as unreadable both publishes (fail-safe) and keeps a tampered response from
// steering the runner elsewhere. The worst case — three 15s attempts plus two
// 2s sleeps — stays well inside the changes job's five-minute budget.
func fetchPublishedCatalog(ctx context.Context, limit int64) ([]byte, error) {
	client := &http.Client{
		Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		if attempt > 1 {
			time.Sleep(2 * time.Second)
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, publishedCatalogURL, nil)
		if err != nil {
			return nil, err
		}
		response, err := client.Do(request)
		if err != nil {
			lastErr = err
			continue
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			lastErr = fmt.Errorf("catalog returned %s", response.Status)
			continue
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, limit))
		response.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}
		return body, nil
	}
	return nil, lastErr
}

func selectPackBehavior(root string, files []string) ([]packtest.MatrixRow, error) {
	runAll := false
	selected := make(map[string]bool)
	for _, file := range files {
		if file == "__run_all__" || packBehaviorSharedPath(file) {
			runAll = true
		}
		parts := strings.Split(file, "/")
		if len(parts) >= 2 && parts[0] == "packs" {
			selected[parts[1]] = true
		}
	}
	plans, err := packtest.Discover(filepath.Join(root, "packs"), "")
	if err != nil {
		return nil, err
	}
	filtered := make([]packtest.PlanRef, 0, len(plans))
	for _, plan := range plans {
		if runAll || selected[plan.Name] {
			filtered = append(filtered, plan)
		}
	}
	return packtest.Matrix(filtered), nil
}

func packBehaviorSharedPath(file string) bool {
	return toolutil.HasAnyPrefix(
		file,
		"tools/cmd/ci/",
		"tools/internal/ci/",
		"dev/test-packs/",
		"tools/cmd/packtest/",
		"tools/internal/packtest/",
		// The harness runs the real runner binary, so every package the action
		// pipeline links is a behavior input — not just the executor and loader.
		// A redaction, path-containment, or output-schema regression must run the
		// behavior rows that pin it.
		"runner/internal/engine/",
		"runner/internal/executor/",
		"runner/internal/packs/",
		"runner/internal/redact/",
		"runner/internal/validation/",
		"runner/internal/expressions/",
		"runner/internal/admission/",
		"runner/internal/audit/",
		"runner/internal/config/",
		"runner/internal/outputschema/",
		"runner/pkg/actionspec/",
		"runner/pkg/packspec/",
	) || slices.Contains([]string{
		".github/workflows/ci.yml",
		".github/workflows/pack-behavior-rows.yml",
		"tools/internal/devtool/pack.go",
		"runner/action.go",
		"runner/common.go",
		"runner/go.mod",
		"runner/go.sum",
		"tools/go.mod",
		"tools/go.sum",
		"go.work",
		"go.work.sum",
	}, file)
}

func isPackFile(file string) bool {
	return strings.HasPrefix(file, "packs/") &&
		!slices.Contains([]string{"packs/AGENTS.md", "packs/CLAUDE.md", "packs/PUBLISHING.md"}, file)
}

func isPackTestFile(file string) bool {
	parts := strings.Split(file, "/")
	return len(parts) >= 3 && parts[0] == "packs" && parts[2] == "test"
}

func (selection Selection) GoModules() []string {
	modules := make([]string, 0, 3)
	if selection.Runner {
		modules = append(modules, "runner")
	}
	if selection.MCP {
		modules = append(modules, "mcp")
	}
	if selection.Tools {
		modules = append(modules, "tools")
	}
	return modules
}

func WriteSelection(ctx context.Context, root, event, base, outputPath, summaryPath string) error {
	selection, err := Select(ctx, root, event, base)
	if err != nil {
		return err
	}
	modules, err := json.Marshal(selection.GoModules())
	if err != nil {
		return err
	}
	packBehavior, err := json.Marshal(selection.PackBehavior)
	if err != nil {
		return err
	}
	output := fmt.Sprintf("portal=%t\nmcp=%t\nrunner=%t\npacks=%t\ninfra=%t\ndeps=%t\nmcp_listing=%t\ngo_modules=%s\nportal_release=%t\npacks_release=%t\nrunner_image=%t\npack_behavior=%s\nsigning_e2e=%t\nsso_e2e=%t\n",
		selection.Portal, selection.MCP, selection.Runner, selection.Packs, selection.Infra, selection.Deps,
		selection.MCPListing, modules,
		selection.PortalRelease, selection.PacksRelease, selection.RunnerImage, packBehavior,
		selection.SigningE2E, selection.SSOE2E)
	if err := appendOrPrint(outputPath, output); err != nil {
		return err
	}

	mark := func(run bool) string {
		if run {
			return "run"
		}
		return "skip"
	}
	summary := fmt.Sprintf("### Gates for this change\n| Area | |\n|---|---|\n| Portal - Test | %s |\n| Portal - Image | %s |\n| Go - Runner | %s |\n| Go - Runner (root) | %s |\n| Go - MCP | %s |\n| MCP - Windows | %s |\n| Go - Tools | %s |\n| Packs - Validate | %s |\n| Packs - Behavior (%d) | %s |\n| Runner - Image | %s |\n| E2E - Signing | %s |\n| E2E - SSO | %s |\n| Terraform - Validate | %s |\n| Dependencies - Release age | %s |\n| Portal - MCP Registry Listing | %s |\n",
		mark(selection.Portal), mark(selection.Portal), mark(selection.Runner), mark(selection.Runner),
		mark(selection.MCP), mark(selection.MCP), mark(selection.Tools), mark(selection.Packs),
		len(selection.PackBehavior), mark(len(selection.PackBehavior) > 0),
		mark(selection.RunnerImage),
		mark(selection.SigningE2E), mark(selection.SSOE2E),
		mark(selection.Infra), mark(selection.Deps),
		mark(selection.MCPListing))
	if summaryPath != "" {
		return appendFile(summaryPath, summary)
	}
	return nil
}

func appendOrPrint(path, contents string) error {
	if path == "" {
		fmt.Print(contents)
		return nil
	}
	return appendFile(path, contents)
}

func appendFile(path, contents string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(contents)
	return err
}
