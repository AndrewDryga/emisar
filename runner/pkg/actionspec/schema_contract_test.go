package actionspec

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func schemaContractAction() *Action {
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

func TestSchema_StringArgMayUseRuntimeDefaultLimit(t *testing.T) {
	action := schemaContractAction()
	action.Args = []Arg{{Name: "query", Type: ArgString}}
	if err := action.Validate(); err != nil {
		t.Fatalf("string arg should use the runtime default when max_length is absent: %v", err)
	}
	action.Args = []Arg{{Name: "query", Type: ArgString, Validation: &Validation{}}}
	if err := action.Validate(); err != nil {
		t.Fatalf("string arg with empty validation should use the runtime default: %v", err)
	}
}

func TestSchema_NoApprovalField(t *testing.T) {
	forbidden := []string{"approval", "requiresapproval", "requireapproval", "needsapproval"}
	for _, schemaType := range []reflect.Type{
		reflect.TypeOf(Action{}),
		reflect.TypeOf(Execution{}),
		reflect.TypeOf(Arg{}),
		reflect.TypeOf(Validation{}),
	} {
		for i := 0; i < schemaType.NumField(); i++ {
			field := schemaType.Field(i)
			name := strings.ToLower(field.Name)
			yamlTag := strings.ToLower(field.Tag.Get("yaml"))
			for _, bad := range forbidden {
				if name == bad || strings.HasPrefix(yamlTag, bad) {
					t.Fatalf("%s has an approval-shaped field %q (yaml %q); approval is risk x policy on the portal, never a pack field",
						schemaType.Name(), field.Name, field.Tag.Get("yaml"))
				}
			}
		}
	}
}
