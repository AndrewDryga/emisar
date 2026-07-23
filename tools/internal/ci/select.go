package ci

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	PackBehavior  []string
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
	if selection.Workflows {
		selection.Portal = true
		selection.Runner = true
		selection.MCP = true
		selection.Tools = true
		selection.Packs = true
		selection.Infra = true
		selection.Deps = true
		selection.MCPListing = true
		selection.SigningE2E = true
		selection.SSOE2E = true
	}
	selection.PackBehavior = selectPackBehavior(root, files, selection.Workflows)
	if event == "push" {
		selection.Portal = true
		selection.PortalRelease = true
	}
	return selection, nil
}

func (selection *Selection) include(file string) {
	if file == "__run_all__" {
		*selection = Selection{
			Portal: true, Runner: true, MCP: true, Tools: true, Packs: true,
			Infra: true, Deps: true, Workflows: true, MCPListing: true,
			PortalRelease: true, PacksRelease: true,
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
	if strings.HasPrefix(file, "runner/") || member(file, "install.sh", "README.md", "go.work", "go.work.sum") {
		selection.Runner = true
	}
	if strings.HasPrefix(file, "mcp/") || member(file, "install-mcp.sh", "go.work", "go.work.sum") {
		selection.MCP = true
	}
	if file == "server.json" {
		selection.MCPListing = true
	}
	if hasAnyPrefix(file, "tools/", "dev/", ".agent/", ".claude/", ".codex/", ".gemini/", "skills/") || strings.Contains(file, "/.agent/") || member(file, "run", "go.work", "go.work.sum") || filepath.Ext(file) == ".md" {
		selection.Tools = true
	}
	if packSource || hasAnyPrefix(file, "runner/internal/packs/", "runner/pkg/packspec/", "runner/pkg/actionspec/") || member(file, "runner/pack.go", "runner/main.go", "runner/go.mod", "runner/go.sum", "go.work", "go.work.sum") {
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
	if hasAnyPrefix(
		file,
		"tools/cmd/signing-e2e/",
		"dev/signing/",
		"runner/internal/signing/",
		"runner/internal/attest/",
		"mcp/internal/signing/",
	) || member(file, "docker-compose.yml", "tools/internal/devtool/e2e.go") {
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

func selectPackBehavior(root string, files []string, workflows bool) []string {
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
	plans, _ := filepath.Glob(filepath.Join(root, "packs", "*", "test", "cases.yaml"))
	var names []string
	for _, path := range plans {
		name := filepath.Base(filepath.Dir(filepath.Dir(path)))
		if runAll || selected[name] {
			names = append(names, name)
		}
	}
	return names
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
	output := fmt.Sprintf("portal=%t\npacks=%t\ninfra=%t\ndeps=%t\nworkflows=%t\nmcp_listing=%t\ngo_modules=%s\nportal_release=%t\npacks_release=%t\npack_behavior=%s\nsigning_e2e=%t\nsso_e2e=%t\n",
		selection.Portal, selection.Packs, selection.Infra, selection.Deps,
		selection.Workflows, selection.MCPListing, modules,
		selection.PortalRelease, selection.PacksRelease, packBehavior,
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
	summary := fmt.Sprintf("### Gates for this change\n| Area | |\n|---|---|\n| Portal - Test | %s |\n| Portal - Image | %s |\n| Go - Runner | %s |\n| Go - MCP | %s |\n| Go - Tools | %s |\n| Packs - Validate | %s |\n| Packs - Behavior (%d) | %s |\n| E2E - Signing | %s |\n| E2E - SSO | %s |\n| Terraform - Validate | %s |\n| Dependencies - Release age | %s |\n| Actions - Validate workflows | %s |\n| Portal - MCP Registry Listing | %s |\n",
		mark(selection.Portal), mark(selection.Portal), mark(selection.Runner),
		mark(selection.MCP), mark(selection.Tools), mark(selection.Packs),
		len(selection.PackBehavior), mark(len(selection.PackBehavior) > 0),
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
