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
	}
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
	output := fmt.Sprintf("portal=%t\npacks=%t\ninfra=%t\ndeps=%t\nworkflows=%t\nmcp_listing=%t\ngo_modules=%s\nportal_release=%t\npacks_release=%t\n",
		selection.Portal, selection.Packs, selection.Infra, selection.Deps, selection.Workflows, selection.MCPListing, modules, selection.PortalRelease, selection.PacksRelease)
	if err := appendOrPrint(outputPath, output); err != nil {
		return err
	}

	mark := func(run bool) string {
		if run {
			return "run"
		}
		return "skip"
	}
	summary := fmt.Sprintf("### Gates for this change\n| Area | |\n|---|---|\n| Portal - Test | %s |\n| Portal - Image | %s |\n| Go - Runner | %s |\n| Go - MCP | %s |\n| Go - Tools | %s |\n| Packs - Validate | %s |\n| Terraform - Validate | %s |\n| Dependencies - Release age | %s |\n| Actions - Validate workflows | %s |\n| Portal - MCP Registry Listing | %s |\n",
		mark(selection.Portal), mark(selection.Portal), mark(selection.Runner), mark(selection.MCP), mark(selection.Tools), mark(selection.Packs), mark(selection.Infra), mark(selection.Deps), mark(selection.Workflows), mark(selection.MCPListing))
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
