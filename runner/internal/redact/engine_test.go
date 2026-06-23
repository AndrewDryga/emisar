package redact

import (
	"reflect"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// litRule and reRule compile a single literal / regex rule for engine tests.
func litRule(t *testing.T, name, literal, repl string) Rule {
	t.Helper()
	r, err := CompileRule(actionspec.RedactionRule{Name: name, Type: "literal", Literal: literal, Replacement: repl})
	if err != nil {
		t.Fatalf("compiling literal rule %q: %v", name, err)
	}
	return r
}

func reRule(t *testing.T, name, pattern, repl string) Rule {
	t.Helper()
	r, err := CompileRule(actionspec.RedactionRule{Name: name, Type: "regex", Pattern: pattern, Replacement: repl})
	if err != nil {
		t.Fatalf("compiling regex rule %q: %v", name, err)
	}
	return r
}

// RSEC-006-T03 — Extend with empty extra returns the receiver unchanged (same
// instance, no copy), when the receiver has rules (redact.go:22-24).
func TestEngine_ExtendEmptyExtraReturnsReceiver(t *testing.T) {
	base := New([]Rule{litRule(t, "b", "B", "[b]")})
	got := base.Extend(nil)
	if got != base {
		t.Fatalf("Extend(nil) should return the receiver as-is, got a different instance")
	}
	got = base.Extend([]Rule{})
	if got != base {
		t.Fatalf("Extend(empty) should return the receiver as-is, got a different instance")
	}
}

// RSEC-006-T04 — Extend on a nil or empty receiver yields a fresh engine of the
// extra rules (redact.go:19-21).
func TestEngine_ExtendNilOrEmptyReceiver(t *testing.T) {
	extra := []Rule{litRule(t, "x", "SECRET", "[x]")}

	t.Run("nil receiver", func(t *testing.T) {
		var nilEng *Engine
		got := nilEng.Extend(extra)
		if got == nil {
			t.Fatal("Extend on nil receiver must return a usable engine, got nil")
		}
		out, _ := got.Apply("a SECRET value")
		if out != "a [x] value" {
			t.Fatalf("extra rule not applied: %q", out)
		}
	})

	t.Run("empty receiver", func(t *testing.T) {
		got := Empty().Extend(extra)
		out, _ := got.Apply("a SECRET value")
		if out != "a [x] value" {
			t.Fatalf("extra rule not applied: %q", out)
		}
	})
}

// RSEC-006-T05 — Apply reports per-rule hit counts only for rules that fired,
// with the correct count, and omits rules that matched nothing (redact.go:45-55).
func TestEngine_ApplyHitsOnlyFiredRules(t *testing.T) {
	e := New([]Rule{
		litRule(t, "fires-twice", "AA", "_"),
		litRule(t, "never-fires", "ZZZ", "_"),
		reRule(t, "digits", "[0-9]+", "#"),
	})
	_, hits := e.Apply("AA xx AA and 12 then 345")

	want := []Hit{
		{Name: "fires-twice", Type: "literal", Count: 2},
		{Name: "digits", Type: "regex", Count: 2},
	}
	if !reflect.DeepEqual(hits, want) {
		t.Fatalf("hits mismatch:\n got %+v\nwant %+v", hits, want)
	}
}

// RSEC-006-T06 — the Hit.Type label is derived from which field the rule set:
// "regex" for a regex rule, "literal" for a literal rule (redact.go:48-51).
func TestEngine_HitTypeLabel(t *testing.T) {
	e := New([]Rule{
		reRule(t, "r", "secret", "[r]"),
		litRule(t, "l", "token", "[l]"),
	})
	_, hits := e.Apply("secret and token")
	if len(hits) != 2 {
		t.Fatalf("expected both rules to fire, got %+v", hits)
	}
	gotType := map[string]string{}
	for _, h := range hits {
		gotType[h.Name] = h.Type
	}
	if gotType["r"] != "regex" {
		t.Errorf("regex rule labeled %q, want %q", gotType["r"], "regex")
	}
	if gotType["l"] != "literal" {
		t.Errorf("literal rule labeled %q, want %q", gotType["l"], "literal")
	}
}

// RSEC-006-T07 — MergeHits sums counts by rule name across multiple streams
// (e.g. stdout + stderr) and preserves first-seen order (redact.go:61-80).
func TestMergeHits_SumsByNamePreservingOrder(t *testing.T) {
	stdout := []Hit{
		{Name: "bearer", Type: "regex", Count: 2},
		{Name: "pem", Type: "regex", Count: 1},
	}
	stderr := []Hit{
		{Name: "pem", Type: "regex", Count: 3},
		{Name: "aws", Type: "regex", Count: 5},
	}
	got := MergeHits(stdout, stderr)
	want := []Hit{
		{Name: "bearer", Type: "regex", Count: 2},
		{Name: "pem", Type: "regex", Count: 4},
		{Name: "aws", Type: "regex", Count: 5},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("MergeHits mismatch:\n got %+v\nwant %+v", got, want)
	}

	// Merging nothing yields an empty (non-panicking) result.
	if out := MergeHits(); len(out) != 0 {
		t.Fatalf("MergeHits() over no batches should be empty, got %+v", out)
	}
}

// RSEC-006-T09 — declaration order is the contract: a broad rule that rewrites a
// token earlier in the list changes whether a later, narrower rule can match.
// This documents that ordering is intentional and load-bearing (redact.go:38-39).
func TestEngine_OrderSensitivityIsIntentional(t *testing.T) {
	broad := litRule(t, "broad", "secret-value", "[MASKED]")
	narrow := reRule(t, "narrow", `secret-value`, "[NARROW]")

	// Broad first: it consumes the token, so the narrow rule never sees it.
	broadFirst := New([]Rule{broad, narrow})
	out, hits := broadFirst.Apply("here is secret-value done")
	if out != "here is [MASKED] done" {
		t.Fatalf("broad-first should win: %q", out)
	}
	if len(hits) != 1 || hits[0].Name != "broad" {
		t.Fatalf("only the broad rule should fire when ordered first, got %+v", hits)
	}

	// Narrow first: the narrow rule fires; the broad literal then no longer
	// matches its now-rewritten output. Same rules, different order, different
	// result — proving order matters by design.
	narrowFirst := New([]Rule{narrow, broad})
	out, hits = narrowFirst.Apply("here is secret-value done")
	if out != "here is [NARROW] done" {
		t.Fatalf("narrow-first should win: %q", out)
	}
	if len(hits) != 1 || hits[0].Name != "narrow" {
		t.Fatalf("only the narrow rule should fire when ordered first, got %+v", hits)
	}
}

// RSEC-006-T10 — Apply scales linearly with rule count and does no per-call
// recompilation. Throughput baseline; no functional assertion.
func BenchmarkEngine_ApplyRuleCount(b *testing.B) {
	rules := make([]Rule, 0, 64)
	for i := 0; i < 64; i++ {
		c, err := CompileRule(actionspec.RedactionRule{
			Name:    "r" + string(rune('A'+i%26)) + string(rune('0'+i/26)),
			Type:    "regex",
			Pattern: `\bzzz` + string(rune('a'+i%26)) + `[0-9]+\b`,
		})
		if err != nil {
			b.Fatal(err)
		}
		rules = append(rules, c)
	}
	e := New(rules)
	input := "the quick brown fox logs INFO at 2026-06-21 with no secrets at all here\n"
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e.Apply(input)
	}
}
