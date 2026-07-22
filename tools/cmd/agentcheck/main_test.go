package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testChecker(t *testing.T) *checker {
	t.Helper()
	return &checker{root: t.TempDir(), out: io.Discard, errOut: io.Discard}
}

func writeTestFile(t *testing.T, root, path, contents string) {
	t.Helper()
	fullPath := filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fullPath, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func hasFailure(check *checker, text string) bool {
	for _, failure := range check.failures {
		if strings.Contains(failure, text) {
			return true
		}
	}
	return false
}

func TestParseFrontmatter(t *testing.T) {
	metadata, err := parseFrontmatter([]byte("---\nname: workflow-test\ndescription: Test workflow\neffort: high\nallowed-tools: Read, Bash\n---\nbody\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got := metadataString(metadata, "name"); got != "workflow-test" {
		t.Fatalf("name = %q", got)
	}
	if got := metadataString(metadata, "allowed-tools"); got != "Read, Bash" {
		t.Fatalf("allowed-tools = %q", got)
	}
}

func TestCheckTaskDirsRejectsUnknownRootState(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/tasks/17_unknown/task-id/task.md", "# task\n")

	check.checkTaskDirs()

	if !hasFailure(check, "unknown state 17_unknown") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckTaskDirsAcceptsLifecycleAndBacklogStates(t *testing.T) {
	check := testChecker(t)
	for _, state := range []string{"00_todo", "10_in_progress", "50_blocked", "99_done", "xx_backlog"} {
		writeTestFile(t, check.root, ".agent/tasks/"+state+"/task-id/task.md", "# task\n")
	}

	check.checkTaskDirs()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckPublicSkillMCPToolsUsesParsedSchema(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "docs/mcp-api-schemas.json", `{"tools":{"list_runners":{}}}`)
	writeTestFile(t, check.root, "skills/operator/SKILL.md", "Use `list_runners` then `get_runner`.\n")

	check.checkPublicSkillMCPTools()

	if !hasFailure(check, `unknown MCP tool "get_runner"`) {
		t.Fatalf("failures = %#v", check.failures)
	}
	if hasFailure(check, `unknown MCP tool "list_runners"`) {
		t.Fatalf("known tool rejected: %#v", check.failures)
	}
}

func TestCheckPublicSkillsRejectsContributorOnlyLists(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "skills/README.md", "# Skills\n")
	writeTestFile(t, check.root, "skills/operator/SKILL.md", "---\nname: operator\ndescription: Operate safely\nallowed-tools: [Read, Bash]\n---\n")

	check.checkPublicSkills()

	if !hasFailure(check, "contributor-only allowed-tools") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestHasJSONKeyFindsNestedHook(t *testing.T) {
	value := map[string]any{"hooks": map[string]any{"Stop": []any{map[string]any{"type": "command"}}}}
	if !hasJSONKey(value, "Stop") {
		t.Fatal("nested Stop hook was not found")
	}
	if hasJSONKey(value, "Start") {
		t.Fatal("missing Start hook was reported")
	}
}
