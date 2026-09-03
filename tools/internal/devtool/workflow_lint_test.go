package devtool

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

func TestWorkflowLintPathsScopesTheSelfReferenceException(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, ".github", "workflows")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"ci.yml", "docs.yaml", "mcp-release-trusted.yml", "runner-release-trusted.yml",
	} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("name: test\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	regular, selfReferenced, err := workflowLintPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	wantRegular := []string{
		filepath.Join(directory, "ci.yml"),
		filepath.Join(directory, "docs.yaml"),
	}
	wantSelfReferenced := []string{
		filepath.Join(directory, "mcp-release-trusted.yml"),
		filepath.Join(directory, "runner-release-trusted.yml"),
	}
	if !reflect.DeepEqual(regular, wantRegular) {
		t.Fatalf("regular workflows = %v, want %v", regular, wantRegular)
	}
	if !reflect.DeepEqual(selfReferenced, wantSelfReferenced) {
		t.Fatalf("self-referenced workflows = %v, want %v", selfReferenced, wantSelfReferenced)
	}
}

func TestActionlintExceptionMatchesOnlyTheKnownFalsePositive(t *testing.T) {
	pattern := regexp.MustCompile(actionlintSelfReferenceFalsePositive)
	known := `specifying action "$/.github/actions/verify-release-tag" in invalid format because ref is missing. available formats are "{owner}/{repo}@{ref}" or "{owner}/{repo}/{path}@{ref}"`
	if !pattern.MatchString(known) {
		t.Fatalf("exception does not match actionlint's known false positive: %q", pattern)
	}
	for _, finding := range []string{
		`specifying action "$/.github/actions/other" in invalid format because ref is missing.`,
		`property "bad" is not defined`,
		`specifying action "./.github/actions/verify-release-tag" in invalid format because ref is missing.`,
	} {
		if pattern.MatchString(finding) {
			t.Fatalf("exception unexpectedly hides %q", finding)
		}
	}
}
