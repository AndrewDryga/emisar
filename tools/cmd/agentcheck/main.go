// Command agentcheck verifies the repository's shared agent configuration:
// canonical instruction links, Coop task conventions, contributor/customer
// skill metadata, public MCP tool references, and scoped workflow hooks.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/repo"
	"go.yaml.in/yaml/v3"
)

var (
	staleManualText = regexp.MustCompile(`coop tasks list|xx_done`)
	staleSkillText  = regexp.MustCompile("(?i)(/code-review|/security-review)|v0\\.2|never shells out|never-a-shell|argv arrays, never shell strings|(^|[[:space:]`(])/(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|make-interfaces-feel-better|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api|work)\\b|`(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api)`")
	publicMCPTool   = regexp.MustCompile("`(list|find|get|run|wait_for|recent|execute|create)_(action|actions|operation|operations|pack|packs|runner|runners|run|runs|runbook|runbooks)(_[a-z0-9]+)*`")
)

type checker struct {
	root     string
	out      io.Writer
	errOut   io.Writer
	failures []string
}

func (c *checker) fail(format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	c.failures = append(c.failures, message)
	fmt.Fprintln(c.errOut, "FAIL:", message)
}

func (c *checker) ok(message string) {
	fmt.Fprintln(c.out, "ok:", message)
}

func (c *checker) group(success string, check func()) {
	before := len(c.failures)
	check()
	if len(c.failures) == before {
		c.ok(success)
	}
}

func (c *checker) path(relative string) string {
	return filepath.Join(c.root, filepath.FromSlash(relative))
}

func (c *checker) expectLink(path, target string) {
	info, err := os.Lstat(c.path(path))
	if err != nil {
		c.fail("stating %s: %v", path, err)
		return
	}
	if info.Mode()&os.ModeSymlink == 0 {
		c.fail("%s is not a symlink", path)
		return
	}
	actual, err := os.Readlink(c.path(path))
	if err != nil {
		c.fail("reading %s: %v", path, err)
		return
	}
	if actual != target {
		c.fail("%s points to %s, expected %s", path, actual, target)
		return
	}
	c.ok(path + " -> " + target)
}

func (c *checker) checkLinks() {
	for _, project := range []string{".", "infra", "mcp", "packs", "portal", "runner"} {
		path := "CLAUDE.md"
		if project != "." {
			path = project + "/CLAUDE.md"
		}
		c.expectLink(path, "AGENTS.md")
	}
	c.expectLink(".codex/skills", "../.claude/skills")
	c.expectLink(".gemini/skills", "../.claude/skills")
}

func (c *checker) scan(paths []string, pattern *regexp.Regexp) []string {
	var findings []string
	for _, relative := range c.files(paths) {
		data, err := os.ReadFile(c.path(relative))
		if err != nil {
			c.fail("reading %s: %v", relative, err)
			continue
		}
		for index, line := range strings.Split(string(data), "\n") {
			if pattern.MatchString(line) {
				findings = append(findings, fmt.Sprintf("%s:%d:%s", relative, index+1, line))
			}
		}
	}
	return findings
}

func (c *checker) files(paths []string) []string {
	var files []string
	for _, relative := range paths {
		fullPath := c.path(relative)
		info, err := os.Stat(fullPath)
		if err != nil {
			c.fail("stating %s: %v", relative, err)
			continue
		}
		if !info.IsDir() {
			files = append(files, filepath.ToSlash(relative))
			continue
		}
		err = filepath.WalkDir(fullPath, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				return nil
			}
			repoRelative, err := filepath.Rel(c.root, path)
			if err != nil {
				return err
			}
			files = append(files, filepath.ToSlash(repoRelative))
			return nil
		})
		if err != nil {
			c.fail("walking %s: %v", relative, err)
		}
	}
	sort.Strings(files)
	return files
}

func (c *checker) checkManualText() {
	paths := []string{
		"AGENTS.md", ".claude/skills", "skills", "portal/AGENTS.md",
		"runner/AGENTS.md", "mcp/AGENTS.md", "packs/AGENTS.md", "infra/AGENTS.md",
	}
	findings := c.scan(paths, staleManualText)
	for _, finding := range findings {
		fmt.Fprintln(c.errOut, finding)
	}
	if len(findings) > 0 {
		c.fail("manuals or skills still mention stale Coop task commands/state names")
	}
}

func (c *checker) checkSkillText() {
	findings := c.scan([]string{".claude/skills", "skills"}, staleSkillText)
	for _, finding := range findings {
		fmt.Fprintln(c.errOut, finding)
	}
	if len(findings) > 0 {
		c.fail("skills still mention retired review commands or stale product/security wording")
	}
}

func (c *checker) checkCoop() {
	help, err := c.command("coop", "tasks", "--help")
	if err != nil {
		c.fail("coop tasks --help failed: %v", err)
		return
	}
	if !bytes.Contains(help, []byte("ls [--all]")) {
		c.fail("coop help no longer advertises 'tasks ls'")
	}
	if !bytes.Contains(help, []byte("99_done/")) {
		c.fail("coop help no longer advertises 99_done/")
	}
	if _, err := c.command("coop", "tasks", "ls", "--all"); err != nil {
		c.fail("coop tasks ls --all failed: %v", err)
	}
}

func (c *checker) command(name string, args ...string) ([]byte, error) {
	command := exec.Command(name, args...)
	command.Dir = c.root
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("%w (%s)", err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func skipGeneratedDirectory(entry fs.DirEntry) bool {
	if !entry.IsDir() {
		return false
	}
	switch entry.Name() {
	case ".git", "deps", "_build", "node_modules":
		return true
	default:
		return false
	}
}

func (c *checker) walkRepository(visit func(string, fs.DirEntry)) {
	err := filepath.WalkDir(c.root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path != c.root && skipGeneratedDirectory(entry) {
			return filepath.SkipDir
		}
		relative, err := filepath.Rel(c.root, path)
		if err != nil {
			return err
		}
		visit(filepath.ToSlash(relative), entry)
		return nil
	})
	if err != nil {
		c.fail("walking repository: %v", err)
	}
}

func (c *checker) checkTaskDirs() {
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		if entry.IsDir() && (relative == ".agent/tasks/xx_done" || strings.HasSuffix(relative, "/.agent/tasks/xx_done")) {
			c.fail("%s has stale xx_done/", strings.TrimSuffix(relative, "/xx_done"))
			return
		}
		if entry.IsDir() || entry.Name() != "task.md" {
			return
		}
		parts := strings.Split(relative, "/")
		for index := 0; index+3 < len(parts); index++ {
			if parts[index] != ".agent" || parts[index+1] != "tasks" {
				continue
			}
			state := parts[index+2]
			switch state {
			case "00_todo", "10_in_progress", "50_blocked", "99_done", "xx_backlog":
			default:
				c.fail("%s lives under unknown state %s", relative, state)
			}
			return
		}
	})
}

func hasPrefix(value string, prefixes []string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}

func (c *checker) checkRuleNames() {
	prefixes := []string{"design-", "content-", "elixir-", "runner-", "mcp-", "packs-", "infra-", "shared-"}
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		isRule := strings.Contains(relative, "/.agent/rules/") || strings.HasPrefix(relative, ".agent/rules/")
		if entry.IsDir() || !strings.HasSuffix(relative, ".md") || !isRule {
			return
		}
		if !hasPrefix(entry.Name(), prefixes) {
			c.fail("%s must use a recognized rule domain prefix", relative)
		}
	})
}

func parseFrontmatter(data []byte) (map[string]any, error) {
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	if len(lines) == 0 || lines[0] != "---" {
		return nil, fmt.Errorf("missing opening frontmatter delimiter")
	}
	end := -1
	for index := 1; index < len(lines); index++ {
		if lines[index] == "---" {
			end = index
			break
		}
	}
	if end < 0 {
		return nil, fmt.Errorf("missing closing frontmatter delimiter")
	}
	frontmatter := make(map[string]any)
	if err := yaml.Unmarshal([]byte(strings.Join(lines[1:end], "\n")), &frontmatter); err != nil {
		return nil, fmt.Errorf("parsing frontmatter: %w", err)
	}
	return frontmatter, nil
}

func metadataString(metadata map[string]any, key string) string {
	value, _ := metadata[key].(string)
	return strings.TrimSpace(value)
}

func metadataNonEmpty(metadata map[string]any, key string) bool {
	value, exists := metadata[key]
	if !exists || value == nil {
		return false
	}
	if text, ok := value.(string); ok {
		return strings.TrimSpace(text) != ""
	}
	return true
}

func (c *checker) skillMetadata(path string) map[string]any {
	data, err := os.ReadFile(c.path(path))
	if err != nil {
		c.fail("reading %s: %v", path, err)
		return nil
	}
	metadata, err := parseFrontmatter(data)
	if err != nil {
		c.fail("%s: %v", path, err)
		return nil
	}
	return metadata
}

func (c *checker) skillFiles(root string) []string {
	entries, err := os.ReadDir(c.path(root))
	if err != nil {
		c.fail("reading %s: %v", root, err)
		return nil
	}
	var files []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := root + "/" + entry.Name() + "/SKILL.md"
		if _, err := os.Stat(c.path(path)); err == nil {
			files = append(files, path)
		}
	}
	sort.Strings(files)
	return files
}

func (c *checker) checkSkills() {
	namePrefixes := []string{"content-", "debug-", "design-", "elixir-", "go-", "ops-", "product-", "review-", "security-", "tooling-", "workflow-"}
	for _, path := range c.skillFiles(".claude/skills") {
		metadata := c.skillMetadata(path)
		if metadata == nil {
			continue
		}
		directory := filepath.Base(filepath.Dir(path))
		name := metadataString(metadata, "name")
		description := metadataString(metadata, "description")
		effort := metadataString(metadata, "effort")
		allowedTools := metadataString(metadata, "allowed-tools")
		if name == "" {
			c.fail("%s missing frontmatter name", path)
		}
		if description == "" {
			c.fail("%s missing frontmatter description", path)
		}
		if effort == "" {
			c.fail("%s missing frontmatter effort", path)
		}
		if allowedTools == "" {
			c.fail("%s missing frontmatter allowed-tools", path)
		}
		switch effort {
		case "low", "medium", "high", "max":
		default:
			c.fail("%s effort %q must be low, medium, high, or max", path, effort)
		}
		if name != directory {
			c.fail("%s name is %q, expected %q", path, name, directory)
		}
		if !hasPrefix(name, namePrefixes) {
			c.fail("%s name %q must use a recognized domain prefix", path, name)
		}
	}
}

func (c *checker) checkPublicSkills() {
	if _, err := os.Stat(c.path("skills/README.md")); err != nil {
		c.fail("skills/README.md is required for customer installation")
	}
	files := c.skillFiles("skills")
	if len(files) == 0 {
		c.fail("skills/ contains no customer SKILL.md files")
	}
	for _, path := range files {
		metadata := c.skillMetadata(path)
		if metadata == nil {
			continue
		}
		directory := filepath.Base(filepath.Dir(path))
		name := metadataString(metadata, "name")
		if name == "" {
			c.fail("%s missing frontmatter name", path)
		}
		if metadataString(metadata, "description") == "" {
			c.fail("%s missing frontmatter description", path)
		}
		if name != directory {
			c.fail("%s name is %q, expected %q", path, name, directory)
		}
		for _, key := range []string{"effort", "argument-hint", "allowed-tools"} {
			if metadataNonEmpty(metadata, key) {
				c.fail("%s uses contributor-only %s frontmatter", path, key)
			}
		}
		if _, err := os.Lstat(c.path(".claude/skills/" + name)); err == nil {
			c.fail("%s is duplicated under .claude/skills/%s", path, name)
		}
	}
}

func (c *checker) checkPublicSkillMCPTools() {
	const schemaPath = "docs/mcp-api-schemas.json"
	data, err := os.ReadFile(c.path(schemaPath))
	if err != nil {
		c.fail("%s is required to validate MCP tool names in public skills", schemaPath)
		return
	}
	var schema struct {
		Tools map[string]json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		c.fail("parsing %s: %v", schemaPath, err)
		return
	}
	if len(schema.Tools) == 0 {
		c.fail("%s contains no MCP tool names", schemaPath)
		return
	}
	for _, path := range c.skillFiles("skills") {
		data, err := os.ReadFile(c.path(path))
		if err != nil {
			c.fail("reading %s: %v", path, err)
			continue
		}
		for _, match := range publicMCPTool.FindAllIndex(data, -1) {
			quoted := string(data[match[0]:match[1]])
			tool := strings.Trim(quoted, "`")
			if _, exists := schema.Tools[tool]; exists {
				continue
			}
			line := bytes.Count(data[:match[0]], []byte("\n")) + 1
			c.fail("%s:%d cites unknown MCP tool %q; update it from %s", path, line, tool, schemaPath)
		}
	}
}

func (c *checker) checkSweepGuard() {
	if _, err := os.Stat(c.path(".claude/skills/workflow-sweep/queue-guard.sh")); err != nil {
		c.fail("the scoped sweep queue-guard.sh is missing")
	}
	skill, err := os.ReadFile(c.path(".claude/skills/workflow-sweep/SKILL.md"))
	if err != nil || !bytes.Contains(skill, []byte("queue-guard.sh")) {
		c.fail("workflow-sweep frontmatter no longer declares its scoped Stop hook")
	}
	for _, path := range []string{".claude/hooks/stop-guard.sh", ".claude/.sweep-active"} {
		if _, err := os.Lstat(c.path(path)); err == nil {
			c.fail("retired %s is back; the sweep guard must remain skill-scoped", path)
		}
	}
	settings, err := os.ReadFile(c.path(".claude/settings.json"))
	if err == nil {
		var value any
		if err := json.Unmarshal(settings, &value); err != nil {
			c.fail("parsing .claude/settings.json: %v", err)
		} else if hasJSONKey(value, "Stop") {
			c.fail(".claude/settings.json carries a project-global Stop hook; the sweep guard must remain skill-scoped")
		}
	} else if !os.IsNotExist(err) {
		c.fail("reading .claude/settings.json: %v", err)
	}
}

func hasJSONKey(value any, key string) bool {
	switch current := value.(type) {
	case map[string]any:
		for currentKey, nested := range current {
			if currentKey == key || hasJSONKey(nested, key) {
				return true
			}
		}
	case []any:
		for _, nested := range current {
			if hasJSONKey(nested, key) {
				return true
			}
		}
	}
	return false
}

func (c *checker) run(requireCoop bool) int {
	c.checkLinks()
	c.group("manuals and skills use current Coop task commands/state names", c.checkManualText)
	c.group("skills use current review commands and product/security wording", c.checkSkillText)
	if _, err := exec.LookPath("coop"); err == nil {
		c.group("Coop task commands and queue listing work", c.checkCoop)
	} else if requireCoop {
		c.fail("coop is required for the live task-command compatibility check")
	} else {
		fmt.Fprintln(c.out, "skip: Coop live command contract (coop is not installed)")
	}
	c.group("task queues use expected state names", c.checkTaskDirs)
	c.group("rule filenames use domain prefixes", c.checkRuleNames)
	c.group("skill frontmatter has matching name/description/effort/allowed-tools and domain prefixes", c.checkSkills)
	c.group("public skills have portable metadata and remain separate from contributor skills", c.checkPublicSkills)
	c.group("public skill MCP tool names exist in docs/mcp-api-schemas.json", c.checkPublicSkillMCPTools)
	c.group("sweep Stop guard is skill-scoped; no retired global guard/sentinel", c.checkSweepGuard)
	if len(c.failures) > 0 {
		fmt.Fprintf(c.errOut, "\nAgent setup audit failed: %d issue(s)\n", len(c.failures))
		return 1
	}
	fmt.Fprintln(c.out, "\nAgent setup audit passed")
	return 0
}

func main() {
	requireCoop := flag.Bool("require-coop", false, "fail when coop is unavailable for its live compatibility check")
	flag.Parse()
	root, err := repo.Root()
	if err != nil {
		fmt.Fprintln(os.Stderr, "agentcheck:", err)
		os.Exit(2)
	}
	os.Exit((&checker{root: root, out: os.Stdout, errOut: os.Stderr}).run(*requireCoop))
}
