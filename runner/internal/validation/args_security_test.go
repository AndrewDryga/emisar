package validation

import (
	"encoding/json"
	"math"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestValidate_ExactJSONIntegerAboveFloatRange(t *testing.T) {
	schema := []actionspec.Arg{{Name: "job_id", Type: actionspec.ArgInteger, Required: true}}
	const jobID int64 = 891_234_567_890_123_456

	out, err := Validate(schema, map[string]any{"job_id": json.Number("891234567890123456")})
	if err != nil {
		t.Fatalf("exact json integer should pass: %v", err)
	}
	if got := out["job_id"]; got != jobID {
		t.Fatalf("job_id = %#v, want exact int64(%d)", got, jobID)
	}

	for _, value := range []json.Number{"891234567890123456.5", "1e999999999999999999999"} {
		if _, err := Validate(schema, map[string]any{"job_id": value}); err == nil {
			t.Fatalf("out-of-contract integer %q must be rejected", value)
		}
	}
}

func TestValidate_RejectsUnsignedIntegerOverflow(t *testing.T) {
	schema := []actionspec.Arg{{Name: "value", Type: actionspec.ArgInteger}}

	if _, err := Validate(schema, map[string]any{"value": uint64(math.MaxInt64) + 1}); err == nil {
		t.Fatal("uint64 above MaxInt64 accepted as an integer")
	}
}
