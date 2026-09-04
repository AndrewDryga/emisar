// Command agentcheck verifies the repository's shared agent configuration:
// canonical instruction links, Coop task conventions, contributor/customer
// skill metadata, KB ownership, public MCP tool references, and the absence of
// project-global Stop hooks.
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
	"time"

	"github.com/andrewdryga/emisar/tools/internal/repo"
	"go.yaml.in/yaml/v3"
)

var (
	staleManualText = regexp.MustCompile("coop tasks list|xx_done|dev/run\\b|\\.agent/screenshots\\b|(^|[[:space:]`/])LOG(\\.archive)?\\.md\\b|(?i:agent log)")
	staleSkillText  = regexp.MustCompile("(?i)(/code-review|/security-review)|v0\\.2|never shells out|never-a-shell|argv arrays, never shell strings|(^|[[:space:]`(])/(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|make-interfaces-feel-better|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api|work)\\b|`(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api)`")
	// Deliberately BROADER than the shipped tool set: its job is to catch a
	// citation of a tool that does not exist, so it cannot be derived from the
	// tools that do. checkPublicSkillMCPTools asserts every shipped name matches
	// it, so a new verb fails the check here instead of silently falling outside
	// it — which is how `update` went missing and left every
	// `update_runbook_draft` citation unvalidated.
	publicMCPTool = regexp.MustCompile("`(list|find|get|run|wait_for|recent|execute|create|update|cancel|approve|deny|describe|search|start|stop)_(action|actions|operation|operations|pack|packs|runner|runners|run|runs|runbook|runbooks)(_[a-z0-9]+)*`")
	cardPolicy    = regexp.MustCompile(`(?i)\bmust\b|\bnever\b|\bdo[[:space:]]+not\b`)
	inlineCode    = regexp.MustCompile("`[^`]*`")
	// The two spellings a skill uses to tell a model what to SEND:
	// `list_packs include=all`, and `list_packs` with `include: "all"`. The
	// second demands a request-intent connector so that prose describing a
	// RESPONSE field is never read as an argument citation.
	skillInlineToolArgs  = regexp.MustCompile("`([a-z_][a-z0-9_]*)((?: +[a-z_][a-z0-9_]*=[^`]*)+)`")
	skillInlineArgName   = regexp.MustCompile(`([a-z_][a-z0-9_]*)=`)
	skillAdjacentToolArg = regexp.MustCompile("`([a-z_][a-z0-9_]*)`[^`\n]{0,24}?\\b(?:with|passing|using)\\b[^`\n]{0,12}`([a-z_][a-z0-9_]*)[[:space:]]*:")
	// The third request spelling: a JSON argument object beside its tool name.
	// It is how a returned continuation is written (`"tool": "list_packs",
	// "arguments": {…}`), how the bridge README and the docs Copy button write a
	// CLI example (`emisar-mcp list_packs '{…}'`), and how the spec writes an
	// input example — the surfaces the `include` rename broke alongside the
	// skills. Only argument-object GLUE may separate the two, so prose that
	// happens to mention a tool before an unrelated brace is not read as a call.
	mcpToolArgumentObject = regexp.MustCompile(`\b([a-z_][a-z0-9_]*)['"\s:,-]{0,24}(?:arguments['"\s:,-]{0,8})?\{`)
	markdownLink          = regexp.MustCompile(`!?\[[^]]*\]\([^)]+\)`)
	elixirFence           = regexp.MustCompile("^```elixir\\s*$")
	fenceClose            = regexp.MustCompile("^```\\s*$")
	// Only a module DEFINITION is judged. A manual's examples reference real
	// modules constantly and correctly — `belongs_to :account,
	// Emisar.Accounts.Account` is the shape we want copied — so matching a bare
	// module reference would flag the examples for being right.
	exampleDefmodule = regexp.MustCompile(`^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do\b`)
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
	// Gemini's only entry point is the root GEMINI.md; it has no per-project
	// equivalent of CLAUDE.md. A copy here instead of a symlink is how a third
	// tool starts reading a stale manual nobody remembers to update.
	c.expectLink("GEMINI.md", "AGENTS.md")
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
		"AGENTS.md", "dev/README.md", ".claude/skills", "skills", ".agent/kb/runbooks", "portal/AGENTS.md",
		"portal/.agent/kb/rules/design-ui-fix-screenshot-proof.md",
		"runner/AGENTS.md", "mcp/AGENTS.md", "packs/AGENTS.md", "infra/AGENTS.md",
	}
	findings := c.scan(paths, staleManualText)
	for _, finding := range findings {
		fmt.Fprintln(c.errOut, finding)
	}
	if len(findings) > 0 {
		c.fail("manuals, runbooks, or skills still mention stale task commands, screenshot paths, or agent logs")
	}
}

func (c *checker) checkDeprecatedAgentLogs() {
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		if entry.IsDir() {
			return
		}
		if relative == ".agent/LOG.md" || relative == ".agent/LOG.archive.md" ||
			strings.HasSuffix(relative, "/.agent/LOG.md") || strings.HasSuffix(relative, "/.agent/LOG.archive.md") {
			c.fail("%s is deprecated; working state belongs in the owning task and git history", relative)
		}
	})
}

// The task README is scanned for retired slash commands alongside the skills,
// not the manuals: the retired-command regex lives in staleSkillText, and this
// file cites skills the same way a manual does. It went unscanned by either,
// which is how six copies of it kept naming /spec and /sweep after the rename.
func (c *checker) checkSkillText() {
	findings := c.scan([]string{".claude/skills", "skills", ".agent/tasks/README.md"}, staleSkillText)
	for _, finding := range findings {
		fmt.Fprintln(c.errOut, finding)
	}
	if len(findings) > 0 {
		c.fail("skills still mention retired review commands or stale product/security wording")
	}
}

// definedElixirModules maps every module the tree actually defines to the file
// that defines it, by reading source rather than compiling: the check that uses
// it runs in the tooling gate, which has no BEAM build to consult.
func (c *checker) definedElixirModules() map[string]string {
	modules := map[string]string{}
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		if entry.IsDir() || (!strings.HasSuffix(relative, ".ex") && !strings.HasSuffix(relative, ".exs")) {
			return
		}
		data, err := os.ReadFile(c.path(relative))
		if err != nil {
			c.fail("reading %s: %v", relative, err)
			return
		}
		for _, line := range strings.Split(string(data), "\n") {
			if match := exampleDefmodule.FindStringSubmatch(line); match != nil {
				modules[match[1]] = relative
			}
		}
	})
	return modules
}

// checkManualExamples keeps every module a manual DEFINES fictional. A template
// has to stay simpler than the code it teaches — the real Runbooks authorizer
// scopes two schemas through a `query_source` case that a new single-schema
// context must not copy — so an example carrying a real module's name reads as
// a mirror of that module, and the next drift report "syncs" the template to
// production code that was never its contract (PR #44 did exactly that, while
// missing four places where the examples contradicted the manual's own rules).
// Naming an example after nothing that exists makes the two readings impossible
// to confuse, and turns a future collision into this failure rather than an
// argument.
func (c *checker) checkManualExamples() {
	defined := c.definedElixirModules()
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		if entry.IsDir() || entry.Name() != "AGENTS.md" {
			return
		}
		data, err := os.ReadFile(c.path(relative))
		if err != nil {
			c.fail("reading %s: %v", relative, err)
			return
		}
		fenced := false
		for index, line := range strings.Split(string(data), "\n") {
			switch {
			case !fenced && elixirFence.MatchString(line):
				fenced = true
			case fenced && fenceClose.MatchString(line):
				fenced = false
			case fenced:
				match := exampleDefmodule.FindStringSubmatch(line)
				if match == nil {
					continue
				}
				if source, ok := defined[match[1]]; ok {
					c.fail("%s:%d example defines %s, which %s already defines — name manual examples after a context that does not exist", relative, index+1, match[1], source)
				}
			}
		}
	})
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

func (c *checker) checkReviewGate() {
	data, err := os.ReadFile(c.path(".agent/project.yaml"))
	if err != nil {
		c.fail("reading .agent/project.yaml: %v", err)
		return
	}
	var project struct {
		Gate   string `yaml:"gate"`
		Review struct {
			Compose string            `yaml:"compose"`
			Env     map[string]string `yaml:"env"`
		} `yaml:"review"`
	}
	if err := yaml.Unmarshal(data, &project); err != nil {
		c.fail("parsing .agent/project.yaml: %v", err)
		return
	}
	if project.Gate != "./run gate review" {
		c.fail(".agent/project.yaml gate is %q, expected ./run gate review", project.Gate)
	}
	if project.Review.Compose == "" {
		c.fail(".agent/project.yaml review.compose is required for exact-candidate gating")
	}
	if project.Review.Env["CI"] != "1" || project.Review.Env["DATABASE_URL"] == "" {
		c.fail(".agent/project.yaml review.env must provide CI=1 and DATABASE_URL")
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
	// .responder is coop's scratch state, and it caches CHECKOUTS OF OTHER
	// REPOSITORIES. Walking into it judged coop's own KB by this repo's rule
	// naming and reported 311 failures about files we neither own nor ship.
	case ".git", "deps", "_build", "node_modules", ".responder":
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
		if entry.IsDir() || !strings.HasSuffix(relative, ".md") || !isKnowledgeRule(relative) {
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

func metadataDate(metadata map[string]any, key string) string {
	switch value := metadata[key].(type) {
	case string:
		return strings.TrimSpace(value)
	case time.Time:
		return value.Format("2006-01-02")
	default:
		return ""
	}
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

func metadataStrings(metadata map[string]any, key string) []string {
	value, exists := metadata[key]
	if !exists {
		return nil
	}
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		text, ok := value.(string)
		if !ok || strings.TrimSpace(text) == "" {
			return nil
		}
		result = append(result, strings.TrimSpace(text))
	}
	return result
}

func markdownBody(data []byte) ([]string, int, error) {
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	if len(lines) == 0 || lines[0] != "---" {
		return nil, 0, fmt.Errorf("missing opening frontmatter delimiter")
	}
	for index := 1; index < len(lines); index++ {
		if lines[index] == "---" {
			return lines[index+1:], index + 2, nil
		}
	}
	return nil, 0, fmt.Errorf("missing closing frontmatter delimiter")
}

func cardPolicyLines(data []byte) ([]int, error) {
	lines, firstLine, err := markdownBody(data)
	if err != nil {
		return nil, err
	}
	var findings []int
	inFence := false
	for index, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## Changelog") {
			break
		}
		if strings.HasPrefix(trimmed, "```") {
			inFence = !inFence
			continue
		}
		if inFence || strings.HasPrefix(trimmed, ">") {
			continue
		}
		prose := inlineCode.ReplaceAllString(line, "")
		prose = markdownLink.ReplaceAllString(prose, "")
		if cardPolicy.MatchString(prose) {
			findings = append(findings, firstLine+index)
		}
	}
	return findings, nil
}

func isKnowledgeRule(relative string) bool {
	return strings.HasPrefix(relative, ".agent/kb/rules/") || strings.Contains(relative, "/.agent/kb/rules/")
}

func isInternalKnowledge(relative string) bool {
	return strings.HasPrefix(relative, ".agent/kb/internal/") || strings.Contains(relative, "/.agent/kb/internal/")
}

func isKnowledgeSpec(relative string) bool {
	return strings.HasPrefix(relative, ".agent/kb/specs/") || strings.Contains(relative, "/.agent/kb/specs/")
}

func isKnowledgeRunbook(relative string) bool {
	return strings.HasPrefix(relative, ".agent/kb/runbooks/") || strings.Contains(relative, "/.agent/kb/runbooks/")
}

func isKnowledgeCard(relative string, entry fs.DirEntry) bool {
	if entry.IsDir() || entry.Name() == "README.md" || !strings.HasSuffix(entry.Name(), ".md") {
		return false
	}
	isKnowledge := strings.HasPrefix(relative, ".agent/kb/") || strings.Contains(relative, "/.agent/kb/")
	return isKnowledge && !isKnowledgeRule(relative) && !isInternalKnowledge(relative) &&
		!isKnowledgeSpec(relative) && !isKnowledgeRunbook(relative)
}

func isLegacyKnowledgeDirectory(relative string) bool {
	return relative == ".agent/reference" || relative == ".agent/rules" ||
		strings.HasSuffix(relative, "/.agent/reference") || strings.HasSuffix(relative, "/.agent/rules")
}

// Step 2 of the taste pipeline says a recorded rule gets a one-line entry in the
// owning AGENTS.md rule index. An unindexed rule file is invisible: nothing in
// the BOOT protocol reads the rules directory, so an agent following it never
// loads the rule, and the correction it captured gets made again. This is the
// mechanical half of that pipeline — the same "graduate it" step the creed asks
// for on every rule it can check.
func (c *checker) checkRulesAreIndexed() {
	manuals := []string{
		"AGENTS.md", "portal/AGENTS.md", "runner/AGENTS.md",
		"mcp/AGENTS.md", "packs/AGENTS.md", "infra/AGENTS.md",
	}
	// Any manual, not the one whose directory holds the file: a shared rule is
	// often indexed by the project it governs (packs-* from packs/AGENTS.md,
	// elixir-model-* from portal/AGENTS.md), and an agent reads the manual for
	// the area it is working in.
	var index []byte
	for _, manual := range manuals {
		data, err := os.ReadFile(c.path(manual))
		if err != nil {
			if !os.IsNotExist(err) {
				c.fail("reading %s: %v", manual, err)
			}
			continue
		}
		index = append(index, data...)
	}

	rulesDirs := []string{
		".agent/kb/rules", "portal/.agent/kb/rules", "runner/.agent/kb/rules",
		"mcp/.agent/kb/rules", "packs/.agent/kb/rules", "infra/.agent/kb/rules",
	}
	checked := 0
	for _, rulesDir := range rulesDirs {
		entries, err := os.ReadDir(c.path(rulesDir))
		if err != nil {
			if !os.IsNotExist(err) {
				c.fail("reading %s: %v", rulesDir, err)
			}
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasSuffix(name, ".md") {
				continue
			}
			checked++
			if !bytes.Contains(index, []byte(name)) {
				c.fail("%s/%s is in no AGENTS.md rule index; an agent following BOOT will never load it",
					rulesDir, name)
			}
		}
	}
	if checked == 0 {
		c.fail("no rule files were found to check; the kb layout moved")
	}
}

func (c *checker) checkKnowledgeCards() {
	if _, err := os.Stat(c.path(".agent/kb/README.md")); err != nil {
		c.fail(".agent/kb/README.md is required as the knowledge index")
	}
	allowedSubsystems := map[string]bool{
		"agent-stack": true,
		"infra":       true,
		"mcp":         true,
		"packs":       true,
		"portal":      true,
		"runner":      true,
	}
	c.walkRepository(func(relative string, entry fs.DirEntry) {
		if entry.IsDir() && relative == "docs" {
			c.fail("retired docs/ is back; repository knowledge lives under .agent/kb")
			return
		}
		if entry.IsDir() && relative == "distribution" {
			c.fail("retired distribution/ is back; tracked packages live under dist")
			return
		}
		if entry.IsDir() && isLegacyKnowledgeDirectory(relative) {
			c.fail("retired %s is back; durable knowledge lives under .agent/kb", relative)
			return
		}
		if !isKnowledgeCard(relative, entry) {
			return
		}
		data, err := os.ReadFile(c.path(relative))
		if err != nil {
			c.fail("reading %s: %v", relative, err)
			return
		}
		metadata, err := parseFrontmatter(data)
		if err != nil {
			c.fail("%s: %v", relative, err)
			return
		}
		name := metadataString(metadata, "name")
		expectedName := strings.TrimSuffix(entry.Name(), ".md")
		if name != expectedName {
			c.fail("%s name is %q, expected %q", relative, name, expectedName)
		}
		description := metadataString(metadata, "description")
		if description == "" {
			c.fail("%s missing frontmatter description", relative)
		} else if cardPolicy.MatchString(description) {
			c.fail("%s description uses normative policy language; move the constraint to .agent/kb/rules", relative)
		}
		subsystem := metadataString(metadata, "subsystem")
		if !allowedSubsystems[subsystem] {
			c.fail("%s subsystem %q is not recognized", relative, subsystem)
		}
		updated := metadataDate(metadata, "updated")
		if _, err := time.Parse("2006-01-02", updated); err != nil {
			c.fail("%s updated %q must use YYYY-MM-DD", relative, updated)
		}
		sources := metadataStrings(metadata, "sources")
		if len(sources) == 0 {
			c.fail("%s needs at least one source path", relative)
		}
		for _, source := range sources {
			if _, err := os.Stat(c.path(source)); err != nil {
				c.fail("%s source %q does not exist", relative, source)
			}
		}
		lines, err := cardPolicyLines(data)
		if err != nil {
			c.fail("%s: %v", relative, err)
			return
		}
		for _, line := range lines {
			c.fail("%s:%d uses normative policy language; move the constraint to .agent/kb/rules", relative, line)
		}
	})
}

func (c *checker) gitIgnored(relative string) (bool, error) {
	command := exec.Command("git", "check-ignore", "--no-index", "--quiet", "--", relative)
	command.Dir = c.root
	err := command.Run()
	if err == nil {
		return true, nil
	}
	if exitError, ok := err.(*exec.ExitError); ok && exitError.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (c *checker) checkDistributionLayout() {
	if _, err := os.Stat(c.path("dist/cursor-plugin")); err != nil {
		c.fail("dist/cursor-plugin is required as the tracked Cursor package")
	}
	for _, test := range []struct {
		path    string
		ignored bool
	}{
		{path: "dist/generated-sentinel", ignored: true},
		{path: "dist/packs/generated-sentinel", ignored: true},
		{path: "dist/cursor-plugin/tracked-sentinel", ignored: false},
	} {
		ignored, err := c.gitIgnored(test.path)
		if err != nil {
			c.fail("checking ignore policy for %s: %v", test.path, err)
			continue
		}
		if ignored != test.ignored {
			c.fail("ignore policy for %s is %t, expected %t", test.path, ignored, test.ignored)
		}
	}

	// The Cursor package ships VERBATIM copies of the public skills. A
	// hand-copied snapshot once drifted three weeks behind and shipped
	// security guidance the live skill forbids, so equality is enforced
	// rather than assumed. The mirrored set is READ FROM THE PACKAGE, never
	// listed here: a hand-maintained list is the same hazard one level up —
	// a fourth mirrored skill would ship compared to nothing, and a mirror
	// with no source under skills/ would ship with no source of truth at
	// all. Byte equality is also what LINTS the mirror: every check the
	// customer-skill phases run over skills/ reaches these files through it.
	mirrored := 0
	mirrorRoot := c.path("dist/cursor-plugin/skills")
	_ = filepath.WalkDir(mirrorRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(mirrorRoot, path)
		if err != nil {
			return nil
		}
		mirrored++
		sourcePath := "skills/" + filepath.ToSlash(relative)
		source, err := os.ReadFile(c.path(sourcePath))
		if err != nil {
			c.fail("dist/cursor-plugin/skills/%s has no source at %s; a mirror without a source has nothing to stay true to",
				filepath.ToSlash(relative), sourcePath)
			return nil
		}
		copied, err := os.ReadFile(path)
		if err != nil {
			c.fail("reading dist/cursor-plugin/skills/%s: %v", filepath.ToSlash(relative), err)
			return nil
		}
		if !bytes.Equal(source, copied) {
			c.fail("dist/cursor-plugin/skills/%s differs from %s; copy the source verbatim",
				filepath.ToSlash(relative), sourcePath)
		}
		return nil
	})
	if mirrored == 0 {
		c.fail("dist/cursor-plugin/skills mirrors no public skill; the equality check has nothing to compare")
	}

	c.checkChatGPTSubmissionAnnotations()

	// `go install …@latest` pins nothing and builds whatever the default
	// branch holds; customer-facing guidance must build packctl from the
	// signed release tag instead.
	for _, root := range []string{
		"skills",
		"dist/cursor-plugin",
		"portal/apps/emisar_web/lib/emisar_web/controllers/marketing_html",
		"runner/cmd/packctl",
	} {
		_ = filepath.WalkDir(c.path(root), func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			if bytes.Contains(data, []byte("packctl@latest")) {
				c.fail("%s recommends packctl@latest; customer-facing guidance must use the signed release tag", path)
			}
			return nil
		})
	}
}

// The OpenAI submission hand-mirrors every tool's behavior hints, and OpenAI
// reviews the app against what it declares. Flipping destructiveHint in the
// portal without editing the submission leaves a destructive tool listed as
// safe — the same hand-copy failure the Cursor mirror above already suffered,
// one file over. The submission omits idempotentHint (OpenAI's shape has no
// such field), so only the three it does carry are compared.
func (c *checker) checkChatGPTSubmissionAnnotations() {
	const (
		schemaPath     = "portal/apps/emisar_web/priv/mcp/api-schemas.json"
		submissionPath = "dist/chatgpt-plugin/chatgpt-app-submission.json"
	)
	type annotated struct {
		Annotations map[string]bool `json:"annotations"`
	}
	load := func(path string) map[string]annotated {
		data, err := os.ReadFile(c.path(path))
		if err != nil {
			c.fail("reading %s: %v", path, err)
			return nil
		}
		var doc struct {
			Tools map[string]annotated `json:"tools"`
		}
		if err := json.Unmarshal(data, &doc); err != nil {
			c.fail("parsing %s: %v", path, err)
			return nil
		}
		if len(doc.Tools) == 0 {
			c.fail("%s declares no tools", path)
			return nil
		}
		return doc.Tools
	}

	schema, submission := load(schemaPath), load(submissionPath)
	if schema == nil || submission == nil {
		return
	}
	for _, name := range sortedKeys(schema) {
		listed, ok := submission[name]
		if !ok {
			c.fail("%s omits MCP tool %q; the OpenAI listing must describe every shipped tool", submissionPath, name)
			continue
		}
		for _, hint := range []string{"readOnlyHint", "destructiveHint", "openWorldHint"} {
			want, declared := schema[name].Annotations[hint]
			if !declared {
				c.fail("%s: tool %q declares no %s", schemaPath, name, hint)
				continue
			}
			if got, ok := listed.Annotations[hint]; !ok || got != want {
				c.fail("%s: tool %q has %s=%t, but the portal declares %t", submissionPath, name, hint, got, want)
			}
		}
	}
	for _, name := range sortedKeys(submission) {
		if _, ok := schema[name]; !ok {
			c.fail("%s lists tool %q that the portal does not ship", submissionPath, name)
		}
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (c *checker) checkCommandSurface() {
	info, err := os.Stat(c.path("run"))
	if err != nil {
		c.fail("root run command is required: %v", err)
	} else {
		if !info.Mode().IsRegular() {
			c.fail("root run command must be a regular file")
		}
		if info.Mode().Perm()&0o111 == 0 {
			c.fail("root run command must be executable")
		}
	}
	if _, err := os.Lstat(c.path("dev/run")); err == nil {
		c.fail("dev/run is retired; the only contributor command surface is root ./run")
	} else if !os.IsNotExist(err) {
		c.fail("stating retired dev/run: %v", err)
	}
}

// installerEnvPattern matches the operator-input namespace of the shipped
// installers. Those scripts keep their own working state unprefixed
// (URL_EXPLICIT, PACKS_EXPLICIT, INSTALL_DIR_EXPLICIT), so inside them an
// EMISAR_ name is always something an operator can set.
var installerEnvPattern = regexp.MustCompile(`EMISAR_[A-Z0-9_]+`)

// checkFrozenInstallerEnv asserts compatibility.md names every environment
// variable the shipped installers read.
//
// The installers freeze at 1.0, and their environment freezes with them whether
// or not anyone wrote it down — so a variable this inventory omits is a variable
// nobody reviews before it becomes permanent. Six were missing when this check
// was written, including EMISAR_ATTESTATION_WORKFLOW, which selects the workflow
// identity Sigstore provenance is matched against.
func (c *checker) checkFrozenInstallerEnv() {
	spec := ".agent/kb/specs/compatibility.md"
	inventory, err := os.ReadFile(c.path(spec))
	if err != nil {
		c.fail("reading %s: %v", spec, err)
		return
	}
	for _, installer := range []string{"install.sh", "install-mcp.sh", "install-mcp.ps1"} {
		script, err := os.ReadFile(c.path(installer))
		if err != nil {
			c.fail("reading %s: %v", installer, err)
			continue
		}
		seen := map[string]bool{}
		for _, name := range installerEnvPattern.FindAllString(string(script), -1) {
			// Labels are a family, documented and matched by their <KEY> form;
			// the bare prefix and the help text's ROLE example are the same var.
			if strings.HasPrefix(name, "EMISAR_RUNNER_LABEL_") {
				name = "EMISAR_RUNNER_LABEL_<KEY>"
			}
			if seen[name] {
				continue
			}
			seen[name] = true
			if !bytes.Contains(inventory, []byte("`"+name+"`")) {
				c.fail("%s reads %s, which %s does not name; document it or remove the read", installer, name, spec)
			}
		}
	}
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
	files := c.skillFiles(".claude/skills")
	// Its public sibling guards this and this one did not: a casing change or one
	// more level of nesting drops all 27 contributor skills out of the walk, and
	// the check still prints `ok:`.
	if len(files) == 0 {
		c.fail(".claude/skills contains no contributor SKILL.md files")
	}
	for _, path := range files {
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

// Read, never edited here: the guard belongs beside the schema it validates
// against, and each of these files is owned elsewhere.
var mcpArgumentSurfaces = []string{
	".agent/kb/specs/mcp-api.md",
	"mcp/README.md",
	"portal/apps/emisar_web/lib/emisar_web/controllers/marketing_html/docs/mcp_reference.html.heex",
}

func (c *checker) checkPublicSkillMCPTools() {
	const schemaPath = "portal/apps/emisar_web/priv/mcp/api-schemas.json"
	data, err := os.ReadFile(c.path(schemaPath))
	if err != nil {
		c.fail("%s is required to validate MCP tool names in public skills", schemaPath)
		return
	}
	var schema struct {
		Defs  map[string]mcpSchemaObject `json:"$defs"`
		Tools map[string]struct {
			InputSchema mcpSchemaObject `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		c.fail("parsing %s: %v", schemaPath, err)
		return
	}
	if len(schema.Tools) == 0 {
		c.fail("%s contains no MCP tool names", schemaPath)
		return
	}
	arguments := make(map[string]map[string]bool, len(schema.Tools))
	for name, tool := range schema.Tools {
		arguments[name] = tool.InputSchema.argumentNames(schema.Defs)
	}
	// The pattern must be able to SEE every tool we ship, or a citation of a
	// near-miss (get_runner for list_runners) is never examined. Assert that here
	// so adding a tool with a new verb fails loudly rather than quietly shrinking
	// this check's reach.
	for name := range schema.Tools {
		if !publicMCPTool.MatchString("`" + name + "`") {
			c.fail("%s ships MCP tool %q that the citation pattern cannot match; widen publicMCPTool", schemaPath, name)
		}
	}

	citations := c.skillFiles("skills")
	if len(citations) == 0 {
		c.fail("skills/ contains no customer SKILL.md files to check MCP tool names in")
	}
	for _, path := range citations {
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
		c.checkSkillToolArguments(path, data, arguments, schemaPath)
		c.checkJSONToolArguments(path, data, arguments, schemaPath)
	}

	// The customer skills were only one of the four surfaces the `availability`
	// -> `include` rename broke. These three are the ones that FREEZE at 1.0 —
	// the normative spec, the bridge's own README, and the docs Copy button an
	// operator pastes into a terminal — so a rename that misses them ships a
	// contract that instructs the caller to send an argument the portal rejects.
	for _, path := range mcpArgumentSurfaces {
		data, err := os.ReadFile(c.path(path))
		if err != nil {
			c.fail("reading %s to validate its MCP arguments: %v", path, err)
			continue
		}
		// Each of the three writes its JSON inside a host language, so the
		// braces and quotes arrive escaped or entity-encoded; scanning the raw
		// bytes finds the objects but reads no keys out of them, which is a
		// check that reports ok having judged nothing.
		if c.checkJSONToolArguments(path, unescapeEmbeddedJSON(data), arguments, schemaPath) == 0 {
			c.fail("%s cites no MCP argument object; the drift guard reads it and has nothing to judge", path)
		}
	}
}

// The docs Copy button holds its JSON inside a HEEx string attribute and prints
// it through HTML entities; both spellings have to become ordinary JSON before
// the object's keys are readable.
func unescapeEmbeddedJSON(data []byte) []byte {
	return []byte(strings.NewReplacer(
		`\"`, `"`,
		"&#123;", "{",
		"&#125;", "}",
		"&quot;", `"`,
	).Replace(string(data)))
}

// Reports how many argument objects it judged, so a surface that stops spelling
// its examples this way fails loudly instead of silently going unchecked.
func (c *checker) checkJSONToolArguments(path string, data []byte, arguments map[string]map[string]bool, schemaPath string) int {
	judged := 0
	for _, match := range mcpToolArgumentObject.FindAllSubmatchIndex(data, -1) {
		accepted, known := arguments[string(data[match[2]:match[3]])]
		if !known {
			continue
		}
		keys, ok := jsonObjectKeys(data[match[1]-1:])
		if !ok {
			continue
		}
		judged++
		for _, key := range keys {
			if accepted[key] {
				continue
			}
			line := bytes.Count(data[:match[0]], []byte("\n")) + 1
			c.fail("%s:%d cites MCP tool %q with unknown argument %q; update it from %s",
				path, line, string(data[match[2]:match[3]]), key, schemaPath)
		}
	}
	return judged
}

// The top-level keys of the JSON object starting at data[0]. Nested objects and
// string contents are skipped rather than parsed: an example is often elided
// ("..."), so it need not be valid JSON to still name its arguments.
func jsonObjectKeys(data []byte) ([]string, bool) {
	var keys []string
	depth := 0
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '{':
			depth++
		case '}':
			if depth--; depth == 0 {
				return keys, true
			}
		case '"':
			end := bytes.IndexByte(data[i+1:], '"')
			if end < 0 {
				return nil, false
			}
			name := string(data[i+1 : i+1+end])
			i += end + 1
			rest := bytes.TrimLeft(data[i+1:], " \t\r\n")
			if depth == 1 && len(rest) > 0 && rest[0] == ':' {
				keys = append(keys, name)
			}
		}
	}
	return nil, false
}

// A tool name that still exists tells us nothing about the ARGUMENTS beside it:
// renaming list_packs' filter `availability` -> `include` left every shipped
// skill (and its Cursor mirror) instructing the model to send an argument the
// portal rejects outright, while this check stayed green on the names alone.
// Only the two unambiguous request spellings are judged, so prose about a
// response field ("`list_packs` returns `availability: executable`") is not
// mistaken for a call.
func (c *checker) checkSkillToolArguments(path string, data []byte, arguments map[string]map[string]bool, schemaPath string) {
	report := func(offset int, tool, argument string) {
		line := bytes.Count(data[:offset], []byte("\n")) + 1
		c.fail("%s:%d cites MCP tool %q with unknown argument %q; update it from %s",
			path, line, tool, argument, schemaPath)
	}
	for _, match := range skillInlineToolArgs.FindAllSubmatchIndex(data, -1) {
		tool := string(data[match[2]:match[3]])
		accepted, known := arguments[tool]
		if !known {
			continue
		}
		for _, argument := range skillInlineArgName.FindAllSubmatch(data[match[4]:match[5]], -1) {
			if name := string(argument[1]); !accepted[name] {
				report(match[0], tool, name)
			}
		}
	}
	for _, match := range skillAdjacentToolArg.FindAllSubmatchIndex(data, -1) {
		tool := string(data[match[2]:match[3]])
		accepted, known := arguments[tool]
		if !known {
			continue
		}
		if name := string(data[match[4]:match[5]]); !accepted[name] {
			report(match[0], tool, name)
		}
	}
}

// The published input schema either lists its properties inline or composes the
// tool's `<name>_arguments` definition through allOf; resolve both so every
// tool reports the argument names it really accepts.
type mcpSchemaObject struct {
	Properties map[string]json.RawMessage `json:"properties"`
	AllOf      []struct {
		Ref string `json:"$ref"`
	} `json:"allOf"`
}

func (o mcpSchemaObject) argumentNames(defs map[string]mcpSchemaObject) map[string]bool {
	names := make(map[string]bool)
	for name := range o.Properties {
		names[name] = true
	}
	for _, member := range o.AllOf {
		for name := range defs[strings.TrimPrefix(member.Ref, "#/$defs/")].Properties {
			names[name] = true
		}
	}
	return names
}

// The Definition of Done binds each commit to its task with a Coop-Task
// trailer, and `coop` reconciles the queue from it after an interruption. A
// line git does not PARSE as a trailer is worse than none — it reads as bound
// and is not — so the commit-msg hook has to exist and stay executable.
func (c *checker) checkCommitMessageHook() {
	hook := c.path(".githooks/commit-msg")
	info, err := os.Stat(hook)
	if err != nil {
		c.fail(".githooks/commit-msg is missing; nothing checks that a Coop-Task line parses as a trailer")
		return
	}
	if info.Mode()&0o111 == 0 {
		c.fail(".githooks/commit-msg is not executable, so git silently skips it")
	}
	body, err := os.ReadFile(hook)
	if err != nil {
		c.fail(".githooks/commit-msg is unreadable: %v", err)
		return
	}
	if !bytes.Contains(body, []byte("interpret-trailers")) {
		c.fail(".githooks/commit-msg no longer asks git whether the line is a trailer")
	}
}

// A Stop hook decides whether a session may end, so a broken one fails OPEN and
// stays silent about it: the queue-guard this repo used to ship could `cd ""` on
// an unset CLAUDE_PROJECT_DIR, read some other tree, and report an empty queue.
// The sweep skill it belonged to is gone; these assertions keep any replacement
// from arriving as a project-global hook, which is the shape that could end a
// session for reasons the session never sees.
func (c *checker) checkNoGlobalStopHook() {
	for _, path := range []string{".claude/hooks/stop-guard.sh", ".claude/.sweep-active"} {
		if _, err := os.Lstat(c.path(path)); err == nil {
			c.fail("retired %s is back; a Stop guard must never be project-global", path)
		}
	}
	// Both files, not just the tracked one: Claude merges settings.local.json
	// over settings.json, so a Stop hook placed there was project-global in
	// effect and invisible to a check that read only the committed file.
	for _, name := range []string{".claude/settings.json", ".claude/settings.local.json"} {
		settings, err := os.ReadFile(c.path(name))
		if err != nil {
			if !os.IsNotExist(err) {
				c.fail("reading %s: %v", name, err)
			}
			continue
		}
		var value any
		if err := json.Unmarshal(settings, &value); err != nil {
			c.fail("parsing %s: %v", name, err)
		} else if hasJSONKey(value, "Stop") {
			c.fail("%s carries a project-global Stop hook; a Stop guard must never be project-global", name)
		}
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
	c.group("manuals, runbooks, and skills use current task commands and state paths", c.checkManualText)
	c.group("deprecated workspace and project agent logs are absent", c.checkDeprecatedAgentLogs)
	c.group("skills use current review commands and product/security wording", c.checkSkillText)
	c.group("manual code examples define only fictional modules", c.checkManualExamples)
	if _, err := exec.LookPath("coop"); err == nil {
		c.group("Coop task commands and queue listing work", c.checkCoop)
	} else if requireCoop {
		c.fail("coop is required for the live task-command compatibility check")
	} else {
		fmt.Fprintln(c.out, "skip: Coop live command contract (coop is not installed)")
	}
	c.group("task queues use expected state names", c.checkTaskDirs)
	c.group("Coop review gates the exact rebased candidate through ./run gate review", c.checkReviewGate)
	c.group("rule filenames use domain prefixes", c.checkRuleNames)
	c.group("repository knowledge uses the KB layout and descriptive cards carry metadata", c.checkKnowledgeCards)
	c.group("tracked dist packages stay separate from generated output", c.checkDistributionLayout)
	c.group("root ./run is the only contributor command surface", c.checkCommandSurface)
	c.group("skill frontmatter has matching name/description/effort/allowed-tools and domain prefixes", c.checkSkills)
	c.group("public skills have portable metadata and remain separate from contributor skills", c.checkPublicSkills)
	c.group("public skill MCP tool names exist in the portal-owned API schema", c.checkPublicSkillMCPTools)
	c.group("no project-global Stop hook or retired sweep sentinel", c.checkNoGlobalStopHook)
	c.group("the commit-msg hook verifies a Coop-Task line parses as a trailer", c.checkCommitMessageHook)
	c.group("every kb rule is indexed by its owning AGENTS.md", c.checkRulesAreIndexed)
	c.group("the compatibility spec names every environment variable the installers read", c.checkFrozenInstallerEnv)
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
