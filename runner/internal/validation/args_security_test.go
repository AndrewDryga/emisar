package validation

import (
	"encoding/json"
	"math"
	"strings"
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

func TestValidate_IntegerBoundsStayExactAboveFloatRange(t *testing.T) {
	max := float64((1 << 53) - 1)
	schema := []actionspec.Arg{{
		Name: "job_id", Type: actionspec.ArgInteger,
		Validation: &actionspec.Validation{Max: &max},
	}}

	if _, err := Validate(schema, map[string]any{"job_id": json.Number("9007199254740991")}); err != nil {
		t.Fatalf("exact boundary should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"job_id": json.Number("9007199254740992")}); err == nil {
		t.Fatal("integer one above exact boundary passed after float rounding")
	}
}

func TestValidate_StringLikeValuesHaveDefaultByteLimit(t *testing.T) {
	tooLong := strings.Repeat("x", defaultMaxStringBytes+1)
	for _, tc := range []struct {
		name  string
		arg   actionspec.Arg
		value any
	}{
		{name: "string", arg: actionspec.Arg{Name: "value", Type: actionspec.ArgString}, value: tooLong},
		{name: "path", arg: actionspec.Arg{Name: "value", Type: actionspec.ArgPath}, value: "/" + tooLong},
		{name: "string array", arg: actionspec.Arg{Name: "value", Type: actionspec.ArgStringArray}, value: []any{tooLong}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := Validate([]actionspec.Arg{tc.arg}, map[string]any{"value": tc.value}); err == nil {
				t.Fatalf("Validate accepted value above the %d-byte default", defaultMaxStringBytes)
			}
		})
	}

	override := defaultMaxStringBytes + 10
	arg := actionspec.Arg{
		Name: "value", Type: actionspec.ArgString,
		Validation: &actionspec.Validation{MaxLength: &override},
	}
	if _, err := Validate([]actionspec.Arg{arg}, map[string]any{"value": tooLong}); err != nil {
		t.Fatalf("explicit max_length should replace the default: %v", err)
	}
}

func TestValidate_RejectsUnsignedIntegerOverflow(t *testing.T) {
	schema := []actionspec.Arg{{Name: "value", Type: actionspec.ArgInteger}}

	if _, err := Validate(schema, map[string]any{"value": uint64(math.MaxInt64) + 1}); err == nil {
		t.Fatal("uint64 above MaxInt64 accepted as an integer")
	}
}

func TestValidate_RejectsNonFiniteNumbers(t *testing.T) {
	min, max := 0.0, 1.0
	schema := []actionspec.Arg{{
		Name: "value",
		Type: actionspec.ArgNumber,
		Validation: &actionspec.Validation{
			Min: &min,
			Max: &max,
		},
	}}

	for name, value := range map[string]any{
		"nan string":          "NaN",
		"positive inf string": "+Inf",
		"negative inf string": "-Inf",
		"nan float":           math.NaN(),
		"positive inf float":  math.Inf(1),
		"negative inf float":  math.Inf(-1),
		"float32 inf":         float32(math.Inf(1)),
		"json number nan":     json.Number("NaN"),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Validate(schema, map[string]any{"value": value}); err == nil {
				t.Fatalf("Validate accepted non-finite value %#v", value)
			}
		})
	}
}
