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
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/packtest"
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
		files = nulStrings(data)
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
	if err := packtest.ValidateRiskChanges(filepath.Join(root, "packs"), files); err != nil {
		return Selection{}, err
	}
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
	packBehavior, err := selectPackBehavior(root, files, selection.Workflows)
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

	packSource := strings.HasPrefix(file, "packs/") && file != "packs/AGENTS.md" && file != "packs/CLAUDE.md" && file != "packs/PUBLISHING.md"
	if strings.HasPrefix(file, "portal/") || member(file, ".dockerignore", "install.sh", "install-mcp.sh", ".tool-versions") {
		selection.Portal = true
		selection.PortalRelease = true
	}
	if file == ".trivyignore.yaml" {
		selection.Portal = true
	}
	if packSource {
		selection.Portal = true
		selection.PortalRelease = true
	}
	// The pack/catalog schema is a cross-language contract: Go writes it, the
	// Portal reads it. Its Portal-side proof (pack_baseline, published_registry,
	// the packs page) lives in the Portal suite, so a Go-only schema change must
	// select Portal too — otherwise CI validates one half of a contract whose
	// halves can only break together.
	if hasAnyPrefix(file, "runner/pkg/packspec/", "runner/pkg/actionspec/", "runner/internal/catalog/") {
		selection.Portal = true
		selection.PortalRelease = true
	}
	// dev/json-corpus is the golden both hostile-JSON validators must agree on;
	// the module boundary forbids sharing their code, so the corpus IS the
	// parity check and a change to it has to run both suites.
	jsonCorpus := strings.HasPrefix(file, "dev/json-corpus/")
	sharedInstallerHarness := hasAnyPrefix(file, "tools/cmd/installtest/", "tools/internal/installtest/harness")
	runnerInstallerHarness := sharedInstallerHarness || strings.HasPrefix(file, "tools/internal/installtest/runner")
	mcpInstallerHarness := sharedInstallerHarness || strings.HasPrefix(file, "tools/internal/installtest/mcp")
	if strings.HasPrefix(file, "runner/") || jsonCorpus || runnerInstallerHarness || member(file, "install.sh", "README.md", "go.work", "go.work.sum") {
		selection.Runner = true
	}
	if strings.HasPrefix(file, "mcp/") || jsonCorpus || mcpInstallerHarness || member(file, "install-mcp.sh", "go.work", "go.work.sum") {
		selection.MCP = true
	}
	if file == "server.json" {
		selection.MCPListing = true
	}
	// .github/workflows and .githooks route here because actionlint and the
	// shell lint both live inside the TOOLING gate. Workflow changes previously
	// set only selection.Workflows, which no job consumes and ci-gate does not
	// require — so a workflow-only PR was linted by nothing while the CI summary
	// printed "Actions - Validate workflows | run". .githooks and .gitignore
	// selected no job at all, though agentcheck asserts the commit-msg hook and
	// the distribution ignore policy from inside that same gate.
	if hasAnyPrefix(file, "tools/", "dev/", ".agent/", ".claude/", ".codex/", ".gemini/", "skills/", ".github/workflows/", ".githooks/") || strings.Contains(file, "/.agent/") || member(file, "run", "go.work", "go.work.sum", ".gitignore", ".tool-versions") || filepath.Ext(file) == ".md" {
		selection.Tools = true
	}
	// Matches the PacksRelease list below, deliberately: validatePacks ends in
	// checkCatalogReproduction, so the code that BUILDS the catalog must run the
	// job that proves the committed catalog still reproduces. Selecting these for
	// release but not validation published a catalog nothing had rebuilt.
	if packSource || hasAnyPrefix(file, "runner/internal/packs/", "runner/internal/catalog/", "runner/cmd/packctl/", "runner/pkg/packspec/", "runner/pkg/actionspec/") || member(file, "runner/pack.go", "runner/main.go", "runner/go.mod", "runner/go.sum", "go.work", "go.work.sum") {
		selection.Packs = true
	}
	if packSource || hasAnyPrefix(file, "runner/internal/packs/", "runner/internal/catalog/", "runner/cmd/packctl/", "runner/pkg/packspec/", "runner/pkg/actionspec/") || member(file, "runner/pack.go", "runner/main.go", "runner/go.mod", "runner/go.sum", "go.work", "go.work.sum") {
		selection.PacksRelease = true
	}
	if strings.HasPrefix(file, "infra/") || file == ".tool-versions" {
		selection.Infra = true
	}
	if member(file, "portal/mix.lock", "runner/go.mod", "runner/go.sum", "mcp/go.mod", "mcp/go.sum", "tools/go.mod", "tools/go.sum", ".dep-age-allow") || strings.HasPrefix(file, "tools/cmd/depgate/") {
		selection.Deps = true
	}
	if strings.HasPrefix(file, ".github/workflows/") || file == ".github/dependabot.yml" {
		selection.Workflows = true
	}
	// Both halves of the signer↔verifier contract, because the e2e drives the
	// real bridge rather than a reimplementation. The bridge's signing seam is
	// mcp/sign.go plus the signer construction in mcp/main.go; there is no
	// mcp/internal/signing package, and naming one here meant a change to
	// attested dispatch on the bridge side skipped the required check entirely.
	if hasAnyPrefix(
		file,
		"tools/cmd/signing-e2e/",
		"dev/signing/",
		"runner/internal/signing/",
		"runner/internal/attest/",
		"mcp/internal/attest/",
	) || member(file, "docker-compose.yml", "tools/internal/devtool/e2e.go", "mcp/sign.go", "mcp/main.go") {
		selection.SigningE2E = true
	}
	if hasAnyPrefix(
		file,
		"tools/cmd/sso-e2e/",
		"dev/keycloak/",
		"portal/apps/emisar/lib/emisar/sso/",
		"portal/apps/emisar_web/lib/emisar_web/controllers/auth",
		"portal/apps/emisar_web/lib/emisar_web/live/sso",
	) || member(file, "docker-compose.yml", "tools/internal/devtool/e2e.go") {
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

func selectPackBehavior(root string, files []string, workflows bool) ([]packtest.MatrixRow, error) {
	runAll := workflows
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
	return hasAnyPrefix(
		file,
		"dev/test-packs/",
		"tools/cmd/packtest/",
		"tools/internal/packtest/",
		"runner/internal/executor/",
		"runner/internal/packs/",
		"runner/pkg/actionspec/",
		"runner/pkg/packspec/",
	) || member(
		file,
		"tools/internal/devtool/pack.go",
		"runner/action.go",
		"runner/config.go",
		"runner/go.mod",
		"runner/go.sum",
		"tools/go.mod",
		"tools/go.sum",
		"go.work",
		"go.work.sum",
	)
}

func member(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if value == candidate {
			return true
		}
	}
	return false
}

func hasAnyPrefix(value string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
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
	output := fmt.Sprintf("portal=%t\npacks=%t\ninfra=%t\ndeps=%t\nworkflows=%t\nmcp_listing=%t\ngo_modules=%s\nportal_release=%t\npacks_release=%t\nrunner_image=%t\npack_behavior=%s\nsigning_e2e=%t\nsso_e2e=%t\n",
		selection.Portal, selection.Packs, selection.Infra, selection.Deps,
		selection.Workflows, selection.MCPListing, modules,
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
	summary := fmt.Sprintf("### Gates for this change\n| Area | |\n|---|---|\n| Portal - Test | %s |\n| Portal - Image | %s |\n| Go - Runner | %s |\n| Go - MCP | %s |\n| Go - Tools | %s |\n| Packs - Validate | %s |\n| Packs - Behavior (%d) | %s |\n| Runner - Image | %s |\n| E2E - Signing | %s |\n| E2E - SSO | %s |\n| Terraform - Validate | %s |\n| Dependencies - Release age | %s |\n| Actions - Validate workflows | %s |\n| Portal - MCP Registry Listing | %s |\n",
		mark(selection.Portal), mark(selection.Portal), mark(selection.Runner),
		mark(selection.MCP), mark(selection.Tools), mark(selection.Packs),
		len(selection.PackBehavior), mark(len(selection.PackBehavior) > 0),
		mark(selection.RunnerImage),
		mark(selection.SigningE2E), mark(selection.SSOE2E),
		mark(selection.Infra), mark(selection.Deps), mark(selection.Workflows),
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
