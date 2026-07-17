package main

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

func TestMissingRequiredEnv(t *testing.T) {
	env := []packspec.EnvVar{
		{Name: "PGHOST", Required: true},
		{Name: "PGPORT"}, // not required → never flagged
		{Name: "PGUSER", Required: true},
	}
	if got := missingRequiredEnv(env, []string{"PATH", "PGHOST"}); len(got) != 1 || got[0] != "PGUSER" {
		t.Fatalf("missingRequiredEnv = %v, want [PGUSER]", got)
	}
	if got := missingRequiredEnv(env, []string{"PGHOST", "PGUSER"}); len(got) != 0 {
		t.Fatalf("expected none missing, got %v", got)
	}
}

func TestRiskSummary(t *testing.T) {
	if s := riskSummary(styler{}, 7, 0, 3, 0); s != "7 low · 3 high" {
		t.Fatalf("riskSummary = %q", s)
	}
	if s := riskSummary(styler{}, 0, 0, 0, 0); s != "none" {
		t.Fatalf("riskSummary empty = %q", s)
	}
}

func TestWrapText(t *testing.T) {
	lines := wrapText("the quick brown fox jumps", 9)
	for _, l := range lines {
		if len(l) > 9 {
			t.Fatalf("line %q exceeds width 9", l)
		}
	}
	if got := strings.Join(lines, " "); got != "the quick brown fox jumps" {
		t.Fatalf("round-trip mismatch: %q", got)
	}
	if wrapText("   ", 5) != nil {
		t.Fatalf("blank input should wrap to nil")
	}
}

func TestEnvDetail(t *testing.T) {
	e := packspec.EnvVar{Description: "Port.", Default: "5432", Example: "5433"}
	got := envDetail(e)
	if !strings.Contains(got, "default: 5432") || !strings.Contains(got, "e.g. 5433") {
		t.Fatalf("envDetail = %q", got)
	}
}
