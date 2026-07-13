package actionspec

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// These tests pin the convention-vs-schema GAPS: house conventions the
// `Validate()` schema check deliberately does NOT enforce, so they are
// caught by human review, not the loader. Each asserts the "bad" shape
// PASSES validation — if a future change starts rejecting one of these,
// this test fails and the author learns the gap closed (or regressed).

// goodAction is a minimal action that Validate() accepts, so each gap test
// mutates exactly the one field under scrutiny.
func goodGapAction() *Action {
	return &Action{
		SchemaVersion: 1,
		ID:            "t.read_thing",
		Title:         "Read thing",
		Kind:          KindExec,
		Risk:          RiskLow,
		Description:   "List the things on the host",
		SideEffects:   []string{"none"},
		Execution: Execution{
			Command: &Command{Binary: "cat", Argv: []string{"/etc/hostname"}},
			Timeout: Duration(5 * time.Second),
		},
		Output: Output{
			Parser:         ParserText,
			MaxStdoutBytes: 1024,
			MaxStderrBytes: 1024,
		},
	}
}

// a read-action description NOT leading with a
// searchable verb (List/Show/Tail/Dump/Count/Check) still validates. The
// verb-leading convention is enforced by review of the MCP catalog text,
// not by the schema.
func TestConventionGap_DescriptionWithoutVerbValidates(t *testing.T) {
	a := goodGapAction()
	// A bare-noun opener an LLM searching "list X" would miss — exactly the
	// shape the convention forbids, yet the schema accepts.
	a.Description = "All active sessions on the node"
	if err := a.Validate(); err != nil {
		t.Fatalf("non-verb-leading description must still validate (convention is review-only), got: %v", err)
	}
}

// a free-form string arg with NO max_length (and no
// pattern/enum) loads clean. An unbounded string is a DoS hole, but bounding
// it is a convention, not a schema requirement.
func TestConventionGap_UnboundedStringArgValidates(t *testing.T) {
	a := goodGapAction()
	a.Args = []Arg{{Name: "query", Type: ArgString}} // no Validation block at all
	if err := a.Validate(); err != nil {
		t.Fatalf("unbounded free-form string arg must still validate (max_length not mandatory), got: %v", err)
	}
	// And explicitly: an empty Validation block (no max_length) is equally fine.
	a.Args = []Arg{{Name: "query", Type: ArgString, Validation: &Validation{}}}
	if err := a.Validate(); err != nil {
		t.Fatalf("string arg with empty validation must still validate, got: %v", err)
	}
}

// a mutating/destructive action mislabeled `risk: low`
// passes Validate(): the schema only checks the risk enum is one of the four
// valid values, never whether the label is HONEST. Mislabeling a mutator as
// low bypasses the approval gate — the single most dangerous authoring error,
// caught only by human review. This test documents that the schema cannot
// catch it.
func TestConventionGap_MislabeledMutatorRiskValidates(t *testing.T) {
	a := goodGapAction()
	a.ID = "t.delete_everything"
	a.Title = "Delete everything"
	a.Description = "Remove all data, irreversibly"
	a.SideEffects = []string{"deletes all data", "irreversible"}
	a.Risk = RiskLow // a lie: this is plainly destructive, yet schema-valid
	a.Execution.Command = &Command{Binary: "rm", Argv: []string{"-rf", "/data"}}
	if err := a.Validate(); err != nil {
		t.Fatalf("a destructive action mislabeled risk:low must still validate (honesty is review-only), got: %v", err)
	}
}

// an absolute, non-/bin/sh binary path validates. The
// "bare PATH-resolved names; /bin/sh is the sole absolute exception"
// convention is enforced by review, not the schema, which never inspects the
// binary string's shape.
func TestConventionGap_AbsoluteBinaryPathValidates(t *testing.T) {
	a := goodGapAction()
	a.Execution.Command = &Command{Binary: "/usr/bin/psql", Argv: []string{"-c", "select 1"}}
	if err := a.Validate(); err != nil {
		t.Fatalf("absolute non-/bin/sh binary must still validate (bare-name convention is review-only), got: %v", err)
	}
}

// (part 1) — there is NO approval field on the Action
// schema. Approval is derived from risk × the portal policy; the struct has
// no `approval`/`requires_approval`/`requires_approval`-shaped field, so a
// manifest declaring one is just ignored YAML. Pin it by reflection so a
// future field addition trips this guard.
func TestSchema_NoApprovalField(t *testing.T) {
	forbidden := []string{"approval", "requiresapproval", "requireapproval", "needsapproval"}
	for _, st := range []reflect.Type{
		reflect.TypeOf(Action{}),
		reflect.TypeOf(Execution{}),
		reflect.TypeOf(Arg{}),
		reflect.TypeOf(Validation{}),
	} {
		for i := 0; i < st.NumField(); i++ {
			name := strings.ToLower(st.Field(i).Name)
			yamlTag := strings.ToLower(st.Field(i).Tag.Get("yaml"))
			for _, bad := range forbidden {
				if name == bad || strings.HasPrefix(yamlTag, bad) {
					t.Fatalf("%s has an approval-shaped field %q (yaml %q); approval is risk × policy on the portal, never a pack field",
						st.Name(), st.Field(i).Name, st.Field(i).Tag.Get("yaml"))
				}
			}
		}
	}
}

// (part 2) — a YAML action carrying an `approval` /
// `requires_approval` key is ACCEPTED: the unknown field is silently
// ignored by the lenient yaml.v3 decode the loader uses, and Validate()
// passes. The key has no effect — it is not a real field — but it does not
// fail the build either.
func TestConventionGap_UnknownApprovalKeyIgnored(t *testing.T) {
	const withApprovalKey = `
schema_version: 1
id: t.thing
title: Thing
kind: exec
risk: high
description: Show the thing
side_effects: [reads state]
approval: required
requires_approval: true
execution:
  command:
    binary: cat
    argv: ["/etc/hostname"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
	var a Action
	if err := yaml.Unmarshal([]byte(withApprovalKey), &a); err != nil {
		t.Fatalf("manifest with an unknown approval key should still parse (lenient YAML), got: %v", err)
	}
	if err := a.Validate(); err != nil {
		t.Fatalf("manifest with an unknown approval key should still validate (unknown YAML ignored), got: %v", err)
	}
	// The unknown key set nothing — Risk came from the real `risk:` field, not
	// the bogus approval keys.
	if a.Risk != RiskHigh {
		t.Fatalf("risk should come from the real risk field, got %q", a.Risk)
	}
}
