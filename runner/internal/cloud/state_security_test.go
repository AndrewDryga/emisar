package cloud

import (
	"reflect"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

func TestStateBuilderAdmissionReloadCannotChangeManifest(t *testing.T) {
	reg := setupRegistry(t)
	policy, err := admission.New(nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	builder := StateBuilder{GetRegistry: func() *packs.Registry { return reg }, GetAdmission: func() *admission.Policy { return policy }}
	allowed := builder.Build()
	policy, err = admission.New([]string{"other.*"}, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	denied := builder.Build()
	if len(allowed.Actions) != 1 || len(denied.Actions) != 1 {
		t.Fatal("admission changed descriptor membership")
	}
	if !allowed.Actions[0].LocalAdmissionAllowed || denied.Actions[0].LocalAdmissionAllowed {
		t.Fatal("admission evidence failed to follow policy reload")
	}
	if !reflect.DeepEqual(allowed.Actions[0].ModelDescriptor, denied.Actions[0].ModelDescriptor) || !reflect.DeepEqual(allowed.Packs, denied.Packs) {
		t.Fatal("local policy changed trusted manifest identity")
	}
	if ok, _ := policy.Admit("t.echo"); ok {
		t.Fatal("advertising a denied descriptor weakened local admission")
	}
}
