package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLinkDestination(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"guide.md":                         "guide.md",
		"guide.md#install":                 "guide.md",
		"<guide%20name.md>":                "guide name.md",
		"guide.md \"title\"":               "guide.md",
		"#local":                           "",
		"/docs/quickstart":                 "",
		"https://emisar.dev/docs/security": "",
		"mailto:security@emisar.dev":       "",
	}
	for raw, want := range cases {
		raw, want := raw, want
		t.Run(raw, func(t *testing.T) {
			t.Parallel()
			if got := linkDestination(raw); got != want {
				t.Fatalf("linkDestination(%q) = %q, want %q", raw, got, want)
			}
		})
	}
}

func TestCheckMarkdownLinks(t *testing.T) {
	t.Parallel()
	tracked := map[string]struct{}{
		"docs/guide.md":     {},
		"docs/images/a.png": {},
		"LICENSE.md":        {},
	}
	data := []byte("[guide](guide.md#top) ![image](images/a.png) [license](../LICENSE.md) [missing](draft.md)")
	got := checkMarkdownLinks("docs/index.md", data, tracked)
	want := []finding{{"docs/index.md", "relative link target is not version-controlled: draft.md"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("findings = %#v, want %#v", got, want)
	}
}

func TestPrivateAgentReferences(t *testing.T) {
	t.Parallel()
	agentReview := ".agent/" + "review"
	agentReviews := agentReview + "s"
	data := []byte("old " + agentReviews + "/round-1; keep .agent/kb/rules/design-system.md")
	want := []string{agentReviews}
	if got := privateAgentReferences(data); !reflect.DeepEqual(got, want) {
		t.Fatalf("privateAgentReferences = %#v, want %#v", got, want)
	}
}

func TestForbiddenVersionedPath(t *testing.T) {
	t.Parallel()
	agentReview := ".agent/" + "reviews/round-1.md"
	cases := map[string]bool{
		".agent/project.yaml":                                 false,
		".agent/loop.yaml":                                    false,
		".agent/Dockerfile":                                   false,
		".agent/compose.yml":                                  true,
		".agent/kb/README.md":                                 false,
		".agent/kb/rules/shared-example.md":                   false,
		".agent/reference/old-card.md":                        true,
		".agent/rules/old-rule.md":                            true,
		".agent/presets/frontier/roles/lead.md":               false,
		agentReview:                                           true,
		"docs/distribution/reviewer-tenant.md":                false,
		"docs/sales/battlecard.md":                            false,
		"docs/security-model.md":                              false,
		"portal/.agent/kb/rules/elixir-doc-contract.md":       false,
		"tools/internal/browser/console.go":                   false,
		"portal/.agent/kb/runner-socket.md":                   false,
		"portal/.agent/compose.yml":                           true,
		"portal/.agent/loop.yaml":                             true,
		"portal/.agent/project.yaml":                          true,
		"portal/.agent/secrets/reviewer.env":                  true,
		"portal/.agent/tasks/00_todo/example/task.md":         true,
		"portal/apps/emisar_web/priv/observability/README.md": false,
	}
	for file, want := range cases {
		file, want := file, want
		t.Run(file, func(t *testing.T) {
			t.Parallel()
			if got := forbiddenVersionedPath(file); got != want {
				t.Fatalf("forbiddenVersionedPath(%q) = %t, want %t", file, got, want)
			}
		})
	}
}

func TestCheckRepositoryIgnoresDeletedTrackedPaths(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
	}
	git("init", "-q")
	path := filepath.Join(root, ".agent", "old", "note.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("# Old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".agent/old/note.md")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}

	findings, _, err := checkRepository(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("findings = %#v", findings)
	}
}
