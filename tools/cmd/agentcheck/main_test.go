package main

import (
	"io"
	"os"
	"os/exec"
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
	writeTestFile(t, check.root, "portal/apps/emisar_web/priv/mcp/api-schemas.json", `{"tools":{"list_runners":{}}}`)
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

func TestCheckKnowledgeCardsAcceptsDescriptiveFacts(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/kb/README.md", "# Knowledge\n")
	writeTestFile(t, check.root, "dev/run", "#!/usr/bin/env bash\n")
	writeTestFile(t, check.root, ".agent/kb/dev-loop.md", `---
name: dev-loop
description: how the development loop resolves services
subsystem: agent-stack
sources: [dev/run]
updated: 2026-07-22
---

The command resolves workspace service URLs before starting Phoenix.
`+"`never`"+` is an external protocol value, not a constraint.
> The external client says do not retry.
[The linked rule says this must stay scoped](rules/shared-example.md).

## Changelog
- 2026-07-22 - created after the caller said it must retain the URL
`)

	check.checkKnowledgeCards()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckKnowledgeCardsRejectsPolicyAndInvalidMetadata(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/kb/README.md", "# Knowledge\n")
	writeTestFile(t, check.root, ".agent/kb/wrong-name.md", `---
name: other-name
description: current behavior
subsystem: unknown
sources: [missing/file]
updated: yesterday
---

The callback must preserve this value.
`)

	check.checkKnowledgeCards()

	for _, expected := range []string{
		`name is "other-name", expected "wrong-name"`,
		`subsystem "unknown" is not recognized`,
		`updated "yesterday" must use YYYY-MM-DD`,
		`source "missing/file" does not exist`,
		`uses normative policy language`,
	} {
		if !hasFailure(check, expected) {
			t.Errorf("missing failure %q in %#v", expected, check.failures)
		}
	}
}

func TestCheckKnowledgeCardsSeparatesInternalMaterialAndRejectsLegacyDirectories(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/kb/README.md", "# Knowledge\n")
	writeTestFile(t, check.root, ".agent/kb/internal/marketing/launch-plan.md", "This draft must remain internal.\n")
	writeTestFile(t, check.root, ".agent/kb/rules/shared-example.md", "# Rule: values must stay scoped\n")
	writeTestFile(t, check.root, "portal/.agent/rules/.gitkeep", "")

	check.checkKnowledgeCards()

	if !hasFailure(check, "retired portal/.agent/rules is back") {
		t.Fatalf("failures = %#v", check.failures)
	}
	if hasFailure(check, ".agent/kb/rules/shared-example.md") {
		t.Fatalf("rule was parsed as a descriptive card: %#v", check.failures)
	}
	if hasFailure(check, ".agent/kb/internal/marketing/launch-plan.md") {
		t.Fatalf("internal material was parsed as a public descriptive card: %#v", check.failures)
	}
}

func TestCheckKnowledgeCardsAcceptsSpecsAndRunbooksButRejectsRetiredRoots(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/kb/README.md", "# Knowledge\n")
	writeTestFile(t, check.root, ".agent/kb/specs/wire-protocol.md", "# Protocol\n\nClients must send a version.\n")
	writeTestFile(t, check.root, ".agent/kb/runbooks/release.md", "# Release\n\nNever publish an unsigned tag.\n")
	writeTestFile(t, check.root, "docs/stale.md", "# Stale\n")
	writeTestFile(t, check.root, "distribution/stale.md", "# Stale\n")

	check.checkKnowledgeCards()

	if !hasFailure(check, "retired docs/ is back") {
		t.Fatalf("failures = %#v", check.failures)
	}
	if !hasFailure(check, "retired distribution/ is back") {
		t.Fatalf("failures = %#v", check.failures)
	}
	if hasFailure(check, ".agent/kb/specs/wire-protocol.md") {
		t.Fatalf("spec was parsed as a descriptive card: %#v", check.failures)
	}
	if hasFailure(check, ".agent/kb/runbooks/release.md") {
		t.Fatalf("runbook was parsed as a descriptive card: %#v", check.failures)
	}
}

func TestCheckDistributionLayoutUsesGitIgnorePolicy(t *testing.T) {
	check := testChecker(t)
	command := exec.Command("git", "init", "--quiet")
	command.Dir = check.root
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v (%s)", err, output)
	}
	writeTestFile(t, check.root, ".gitignore", "/dist/*\n!/dist/cursor-plugin/\n")
	writeTestFile(t, check.root, "dist/cursor-plugin/README.md", "# Cursor\n")

	check.checkDistributionLayout()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}

	writeTestFile(t, check.root, ".gitignore", "/dist/\n")
	check = &checker{root: check.root, out: io.Discard, errOut: io.Discard}
	check.checkDistributionLayout()
	if !hasFailure(check, "dist/cursor-plugin/tracked-sentinel") {
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
