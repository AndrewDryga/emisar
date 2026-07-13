package main

import (
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

func TestRetiredReferences(t *testing.T) {
	t.Parallel()
	agentReview := ".agent/" + "review"
	agentReviews := agentReview + "s"
	deployDoc := "docs/" + "deploy.md"
	internalDistributionDoc := "docs/distribution/" + "reviewer-tenant.md"
	internalSalesDir := "docs/" + "sales"
	data := []byte("old " + agentReviews + "/round-1 and " + deployDoc +
		" plus " + internalDistributionDoc + " and " + internalSalesDir +
		"/battlecard.md; keep .agent/rules/design-system.md")
	want := []string{agentReviews, deployDoc, internalDistributionDoc, internalSalesDir}
	if got := retiredReferences(data); !reflect.DeepEqual(got, want) {
		t.Fatalf("retiredReferences = %#v, want %#v", got, want)
	}
}

func TestForbiddenVersionedPath(t *testing.T) {
	t.Parallel()
	agentReview := ".agent/" + "reviews/round-1.md"
	reviewerDoc := "docs/distribution/" + "reviewer-tenant.md"
	salesDoc := "docs/" + "sales/battlecard.md"
	cases := map[string]bool{
		".agent/project.yaml":                 false,
		agentReview:                           true,
		reviewerDoc:                           true,
		salesDoc:                              true,
		"docs/security-model.md":              false,
		"portal/.agent/rules/doc-contract.md": false,
		"portal/.agent/scripts/capture-console-audit.mjs":     false,
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
