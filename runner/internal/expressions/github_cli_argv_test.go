package expressions

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"go.yaml.in/yaml/v3"
)

func githubCLIAction(t *testing.T, name string) actionspec.Action {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "packs", "github-cli", "actions", name+".yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var action actionspec.Action
	if err := yaml.Unmarshal(raw, &action); err != nil {
		t.Fatal(err)
	}
	return action
}

func TestGitHubCLIIssueCommentsJSON(t *testing.T) {
	action := githubCLIAction(t, "issue_view")
	argv, err := RenderArgv(action.Execution.Command.Argv, map[string]any{"repo": "owner/repo", "issue": 7})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"issue", "view", "7", "--repo", "owner/repo", "--json", "number,title,body,state,author,labels,comments,createdAt"}
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("comments must be fetched by the JSON field, not the conflicting flag: %#v", argv)
	}
}

func TestGitHubCLISearchTermsAndBounds(t *testing.T) {
	action := githubCLIAction(t, "search_prs")
	terms := []string{"repo:owner/repo", "state:open", "-label:wontfix", "label:help wanted", "--web", "$(touch injected)"}
	args, err := validation.Validate(action.Args, map[string]any{"query": terms, "limit": 37}, nil)
	if err != nil {
		t.Fatal(err)
	}
	argv, err := RenderArgv(action.Execution.Argv, args)
	if err != nil {
		t.Fatal(err)
	}
	want := append([]string{"37"}, terms...)
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("whole array elements must remain separate literal script operands: got %#v want %#v", argv, want)
	}
	args, err = validation.Validate(action.Args, map[string]any{"query": []string{"author:@me"}}, nil)
	if err != nil || args["limit"] != int64(100) {
		t.Fatalf("default limit: %#v, %v", args, err)
	}
	for _, test := range []struct {
		name string
		args map[string]any
	}{
		{"missing query", map[string]any{}},
		{"old joined query", map[string]any{"query": "repo:owner/repo state:open"}},
		{"too many terms", map[string]any{"query": make([]string, 17)}},
		{"oversized term", map[string]any{"query": []string{strings.Repeat("a", 513)}}},
		{"limit zero", map[string]any{"query": []string{"state:open"}, "limit": 0}},
		{"limit overflow", map[string]any{"query": []string{"state:open"}, "limit": 101}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := validation.Validate(action.Args, test.args, nil); err == nil {
				t.Fatalf("invalid args accepted: %#v", test.args)
			}
		})
	}
}

func TestGitHubCLIPRReadsUseTheSharedCheckProjection(t *testing.T) {
	for _, test := range []struct{ action, mode string }{{"pr_checks", "checks"}, {"pr_view", "view"}} {
		t.Run(test.action, func(t *testing.T) {
			action := githubCLIAction(t, test.action)
			if action.Execution.Script == nil || action.Execution.Script.Path != "scripts/pr_checks.sh" || action.Execution.Script.Interpreter != "/bin/sh" {
				t.Fatalf("PR read does not use the tested shared script: %#v", action.Execution)
			}
			args, err := validation.Validate(action.Args, map[string]any{"repo": "owner/repo", "pr": 7}, nil)
			if err != nil {
				t.Fatal(err)
			}
			argv, err := RenderArgv(action.Execution.Argv, args)
			if err != nil || !reflect.DeepEqual(argv, []string{test.mode, "owner/repo", "7"}) {
				t.Fatalf("PR script dispatch operands: %#v, %v", argv, err)
			}
		})
	}
}
