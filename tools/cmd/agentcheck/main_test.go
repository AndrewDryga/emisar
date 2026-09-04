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

func TestStaleManualTextRejectsGlobalScreenshotDirectory(t *testing.T) {
	if !staleManualText.MatchString("write to .agent/screenshots/example") {
		t.Fatal("global screenshot directory is not treated as stale guidance")
	}
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

func TestCheckReviewGateRequiresCanonicalCandidateGate(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, ".agent/project.yaml", "gate: ./run gate portal\nreview:\n  compose: dev/review-compose.yml\n  env:\n    CI: '1'\n    DATABASE_URL: postgres://db\n")

	check.checkReviewGate()

	if !hasFailure(check, "expected ./run gate review") {
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
	writeTestFile(t, check.root, "run", "#!/usr/bin/env bash\n")
	writeTestFile(t, check.root, ".agent/kb/dev-loop.md", `---
name: dev-loop
description: how the development loop resolves services
subsystem: agent-stack
sources: [run]
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

func TestCheckCommandSurfaceRequiresExecutableRootRun(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "run", "#!/usr/bin/env bash\n")

	check.checkCommandSurface()

	if !hasFailure(check, "must be executable") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckCommandSurfaceRejectsRetiredDevRun(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "run", "#!/usr/bin/env bash\n")
	if err := os.Chmod(filepath.Join(check.root, "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, check.root, "dev/run", "#!/usr/bin/env bash\n")

	check.checkCommandSurface()

	if !hasFailure(check, "dev/run is retired") {
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
	for _, skill := range []string{"author-pack", "install-emisar", "respond-to-production-incidents"} {
		writeTestFile(t, check.root, "skills/"+skill+"/SKILL.md", "# "+skill+"\n")
		writeTestFile(t, check.root, "dist/cursor-plugin/skills/"+skill+"/SKILL.md", "# "+skill+"\n")
	}
	writeSubmissionFixtures(t, check.root, false)

	check.checkDistributionLayout()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}

	// A drifted mirror is the exact bug this check exists for.
	writeTestFile(t, check.root, "dist/cursor-plugin/skills/author-pack/SKILL.md", "# stale\n")
	check = &checker{root: check.root, out: io.Discard, errOut: io.Discard}
	check.checkDistributionLayout()
	if !hasFailure(check, "dist/cursor-plugin/skills/author-pack/SKILL.md differs") {
		t.Fatalf("drifted mirror not reported: %#v", check.failures)
	}
	writeTestFile(t, check.root, "dist/cursor-plugin/skills/author-pack/SKILL.md", "# author-pack\n")

	// Customer-facing guidance must never recommend an unpinned install.
	writeTestFile(t, check.root, "skills/author-pack/extras.md", "go install example/packctl@latest\n")
	check = &checker{root: check.root, out: io.Discard, errOut: io.Discard}
	check.checkDistributionLayout()
	if !hasFailure(check, "packctl@latest") {
		t.Fatalf("packctl@latest guidance not reported: %#v", check.failures)
	}
	if err := os.Remove(filepath.Join(check.root, "skills", "author-pack", "extras.md")); err != nil {
		t.Fatal(err)
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

func TestCheckManualExamplesRejectsExampleNamedAfterRealModule(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "portal/apps/emisar/lib/emisar/runbooks/authorizer.ex", "defmodule Emisar.Runbooks.Authorizer do\nend\n")
	writeTestFile(t, check.root, "portal/AGENTS.md", "```elixir\ndefmodule Emisar.Runbooks.Authorizer do\nend\n```\n")

	check.checkManualExamples()

	if !hasFailure(check, "example defines Emisar.Runbooks.Authorizer") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

// The examples reference real modules on purpose — a belongs_to naming the real
// Account IS the shape we want copied — so only the defmodule line is judged.
func TestCheckManualExamplesAcceptsFictionalModuleReferencingRealOnes(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "portal/apps/emisar/lib/emisar/accounts/account.ex", "defmodule Emisar.Accounts.Account do\nend\n")
	writeTestFile(t, check.root, "portal/AGENTS.md", "```elixir\ndefmodule Emisar.Widgets.Widget do\n  belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]\nend\n```\n")

	check.checkManualExamples()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckManualExamplesIgnoresNonElixirFences(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "portal/apps/emisar/lib/emisar/runbooks/authorizer.ex", "defmodule Emisar.Runbooks.Authorizer do\nend\n")
	writeTestFile(t, check.root, "portal/AGENTS.md", "```text\ndefmodule Emisar.Runbooks.Authorizer do\nend\n```\n")

	check.checkManualExamples()

	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}
}

// The submission's hints are hand-copied from the portal's schema, so both
// directions matter: a hint that disagrees, a shipped tool the listing omits,
// and a listed tool the portal does not ship.
func writeSubmissionFixtures(t *testing.T, root string, drifted bool) {
	t.Helper()
	destructive := "true"
	if drifted {
		destructive = "false"
	}
	writeTestFile(t, root, "portal/apps/emisar_web/priv/mcp/api-schemas.json", `{"tools":{
		"list_packs":{"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
		"run_action":{"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}}}`)
	writeTestFile(t, root, "dist/chatgpt-plugin/chatgpt-app-submission.json", `{"tools":{
		"list_packs":{"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}},
		"run_action":{"annotations":{"readOnlyHint":false,"openWorldHint":true,"destructiveHint":`+destructive+`}}}}`)
}

func TestCheckChatGPTSubmissionAnnotationsCatchesEveryDirectionOfDrift(t *testing.T) {
	for _, tc := range []struct {
		name    string
		arrange func(t *testing.T, root string)
		want    string
	}{
		{"a hint that disagrees with the portal", func(t *testing.T, root string) {
			writeSubmissionFixtures(t, root, true)
		}, `tool "run_action" has destructiveHint=false, but the portal declares true`},

		{"a shipped tool the listing omits", func(t *testing.T, root string) {
			writeSubmissionFixtures(t, root, false)
			writeTestFile(t, root, "dist/chatgpt-plugin/chatgpt-app-submission.json",
				`{"tools":{"list_packs":{"annotations":{"readOnlyHint":true,"openWorldHint":false,"destructiveHint":false}}}}`)
		}, `omits MCP tool "run_action"`},

		{"a listed tool the portal does not ship", func(t *testing.T, root string) {
			writeSubmissionFixtures(t, root, false)
			writeTestFile(t, root, "portal/apps/emisar_web/priv/mcp/api-schemas.json",
				`{"tools":{"list_packs":{"annotations":{"readOnlyHint":true,"destructiveHint":false,"openWorldHint":false}}}}`)
		}, `lists tool "run_action" that the portal does not ship`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			check := testChecker(t)
			tc.arrange(t, check.root)
			check.checkChatGPTSubmissionAnnotations()
			if !hasFailure(check, tc.want) {
				t.Fatalf("failures = %#v", check.failures)
			}
		})
	}

	check := testChecker(t)
	writeSubmissionFixtures(t, check.root, false)
	check.checkChatGPTSubmissionAnnotations()
	if len(check.failures) != 0 {
		t.Fatalf("matching annotations reported failures: %#v", check.failures)
	}
}

const testMCPSchema = `{"tools":{"list_packs":{"inputSchema":{"properties":{"include":{},"limit":{}}}}}}`

// The four surfaces the `availability` -> `include` rename broke. Three of them
// freeze at 1.0, and none of them was read by the guard that rename added.
func TestCheckPublicSkillMCPToolsRejectsRenamedArgumentOnFrozenSurfaces(t *testing.T) {
	for _, surface := range mcpArgumentSurfaces {
		t.Run(surface, func(t *testing.T) {
			check := testChecker(t)
			writeTestFile(t, check.root, "portal/apps/emisar_web/priv/mcp/api-schemas.json", testMCPSchema)
			writeTestFile(t, check.root, "skills/install-emisar/SKILL.md", "---\nname: install-emisar\n---\nbody\n")
			for _, path := range mcpArgumentSurfaces {
				body := "emisar-mcp list_packs '{\"include\":\"all\"}'\n"
				if path == surface {
					body = "emisar-mcp list_packs '{\"availability\":\"all\"}'\n"
				}
				writeTestFile(t, check.root, path, body)
			}

			check.checkPublicSkillMCPTools()

			if !hasFailure(check, `cites MCP tool "list_packs" with unknown argument "availability"`) {
				t.Fatalf("failures = %#v", check.failures)
			}
		})
	}
}

// The docs Copy button holds its JSON inside a HEEx attribute, so the object is
// found but reads as empty unless the embedded escaping is undone first.
func TestCheckPublicSkillMCPToolsReadsEscapedCopyButtonArguments(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "portal/apps/emisar_web/priv/mcp/api-schemas.json", testMCPSchema)
	writeTestFile(t, check.root, "skills/install-emisar/SKILL.md", "---\nname: install-emisar\n---\nbody\n")
	for _, path := range mcpArgumentSurfaces {
		writeTestFile(t, check.root, path, "emisar-mcp list_packs '{\"include\":\"all\"}'\n")
	}
	writeTestFile(t, check.root, mcpArgumentSurfaces[2],
		`<.docs_code copy_text={"emisar-mcp list_packs '{\"availability\":\"all\"}'"}>`+
			"\n"+`$ emisar-mcp list_packs '&#123;&quot;availability&quot;:&quot;all&quot;&#125;'`+"\n")

	check.checkPublicSkillMCPTools()

	if !hasFailure(check, `cites MCP tool "list_packs" with unknown argument "availability"`) {
		t.Fatalf("failures = %#v", check.failures)
	}
}

// A surface that stops spelling its examples this way is a check that quietly
// stopped checking, which is the failure this whole guard exists to prevent.
func TestCheckPublicSkillMCPToolsRejectsSurfaceWithNoArgumentObject(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "portal/apps/emisar_web/priv/mcp/api-schemas.json", testMCPSchema)
	writeTestFile(t, check.root, "skills/install-emisar/SKILL.md", "---\nname: install-emisar\n---\nbody\n")
	for _, path := range mcpArgumentSurfaces {
		writeTestFile(t, check.root, path, "emisar-mcp list_packs '{\"include\":\"all\"}'\n")
	}
	writeTestFile(t, check.root, mcpArgumentSurfaces[1], "The bridge speaks MCP.\n")

	check.checkPublicSkillMCPTools()

	if !hasFailure(check, "cites no MCP argument object") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

// Prose naming a tool before an unrelated brace is not a call.
func TestJSONObjectKeysIgnoresProseBeforeAnUnrelatedBrace(t *testing.T) {
	check := testChecker(t)
	arguments := map[string]map[string]bool{"list_packs": {"include": true}}
	body := []byte("Use list_packs to browse the catalog. A pack manifest looks like\n\n" +
		"```yaml\nschema_version: 1\n```\n\n{\"availability\": \"all\"}\n")

	if judged := check.checkJSONToolArguments("doc.md", body, arguments, "schema.json"); judged != 0 {
		t.Fatalf("judged = %d, want 0", judged)
	}
	if len(check.failures) != 0 {
		t.Fatalf("failures = %#v", check.failures)
	}
}

// The mirrored set is read from the package: a hand-maintained list is how a
// fourth mirrored skill would ship compared to nothing.
func TestCheckDistributionLayoutComparesEveryMirroredSkill(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "skills/connect-llm/SKILL.md", "source\n")
	writeTestFile(t, check.root, "dist/cursor-plugin/skills/connect-llm/SKILL.md", "drifted\n")

	check.checkDistributionLayout()

	if !hasFailure(check, "dist/cursor-plugin/skills/connect-llm/SKILL.md differs from skills/connect-llm/SKILL.md") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckDistributionLayoutRejectsMirrorWithNoSource(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "dist/cursor-plugin/skills/invented/SKILL.md", "no source\n")

	check.checkDistributionLayout()

	if !hasFailure(check, "has no source at skills/invented/SKILL.md") {
		t.Fatalf("failures = %#v", check.failures)
	}
}

func TestCheckDistributionLayoutRejectsEmptyMirror(t *testing.T) {
	check := testChecker(t)
	writeTestFile(t, check.root, "dist/cursor-plugin/README.md", "package\n")

	check.checkDistributionLayout()

	if !hasFailure(check, "mirrors no public skill") {
		t.Fatalf("failures = %#v", check.failures)
	}
}
