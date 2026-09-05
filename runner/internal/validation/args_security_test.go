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

	out, err := Validate(schema, map[string]any{"job_id": json.Number("891234567890123456")}, nil)
	if err != nil {
		t.Fatalf("exact json integer should pass: %v", err)
	}
	if got := out["job_id"]; got != jobID {
		t.Fatalf("job_id = %#v, want exact int64(%d)", got, jobID)
	}

	for _, value := range []json.Number{"891234567890123456.5", "1e999999999999999999999"} {
		if _, err := Validate(schema, map[string]any{"job_id": value}, nil); err == nil {
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

	if _, err := Validate(schema, map[string]any{"job_id": json.Number("9007199254740991")}, nil); err != nil {
		t.Fatalf("exact boundary should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"job_id": json.Number("9007199254740992")}, nil); err == nil {
		t.Fatal("integer one above exact boundary passed after float rounding")
	}
}

func TestValidate_JSONNumberMembership(t *testing.T) {
	for _, tc := range []struct {
		name       string
		validation *actionspec.Validation
	}{
		{name: "enum", validation: &actionspec.Validation{Enum: []any{1.25, 2.5}}},
		{name: "allowed", validation: &actionspec.Validation{Allowed: []any{1.25, 2.5}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			schema := []actionspec.Arg{{Name: "ratio", Type: actionspec.ArgNumber, Validation: tc.validation}}

			out, err := Validate(schema, map[string]any{"ratio": json.Number("1.250")}, nil)
			if err != nil {
				t.Fatalf("cloud JSON number in numeric membership should pass: %v", err)
			}
			if got := out["ratio"]; got != json.Number("1.250") {
				t.Fatalf("ratio = %#v, want the exact cloud representation", got)
			}
			if _, err := Validate(schema, map[string]any{"ratio": json.Number("1.3")}, nil); err == nil {
				t.Fatal("cloud JSON number outside numeric membership should fail")
			}
		})
	}

	// Integer membership stays exact: an id past 2^53 must not match its
	// neighbour the way both would after a float64 round trip.
	ids := []actionspec.Arg{{
		Name: "id",
		Type: actionspec.ArgInteger,
		Validation: &actionspec.Validation{
			Allowed: []any{int64(9_007_199_254_740_992)},
		},
	}}
	if _, err := Validate(ids, map[string]any{"id": json.Number("9007199254740992")}, nil); err != nil {
		t.Fatalf("the allowed id itself should pass: %v", err)
	}
	if _, err := Validate(ids, map[string]any{"id": json.Number("9007199254740993")}, nil); err == nil {
		t.Fatal("integer above the float64 exact range matched its neighbour in allowed")
	}

	zero := []actionspec.Arg{{
		Name:       "value",
		Type:       actionspec.ArgNumber,
		Validation: &actionspec.Validation{Enum: []any{0}},
	}}
	for _, value := range []json.Number{"0", "-0", "0.0"} {
		if _, err := Validate(zero, map[string]any{"value": value}, nil); err != nil {
			t.Fatalf("zero %s should match zero membership: %v", value, err)
		}
	}
	if _, err := Validate(zero, map[string]any{"value": json.Number("0.5")}, nil); err == nil {
		t.Fatal("a nonzero value matched zero membership")
	}
}

// A number arg keeps its literal for the script, but min/max ask what that
// literal denotes, in float64.
func TestValidate_NumberBoundsCompareAsFloat64(t *testing.T) {
	max := 1.25
	schema := []actionspec.Arg{{
		Name:       "ratio",
		Type:       actionspec.ArgNumber,
		Validation: &actionspec.Validation{Max: &max},
	}}
	if _, err := Validate(schema, map[string]any{"ratio": json.Number("1.25")}, nil); err != nil {
		t.Fatalf("exact max should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"ratio": json.Number("1.2501")}, nil); err == nil {
		t.Fatal("a value above max passed")
	}

	min := 0.0
	schema[0].Validation = &actionspec.Validation{Min: &min}
	if _, err := Validate(schema, map[string]any{"ratio": json.Number("0.5")}, nil); err != nil {
		t.Fatalf("a value above min should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"ratio": json.Number("-0.5")}, nil); err == nil {
		t.Fatal("a value below min passed")
	}
	// A literal too small for float64 denotes zero, so it clears a zero minimum
	// however it was spelled.
	if _, err := Validate(schema, map[string]any{"ratio": json.Number("-1e-400")}, nil); err != nil {
		t.Fatalf("an underflowing literal denotes zero: %v", err)
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
			if _, err := Validate([]actionspec.Arg{tc.arg}, map[string]any{"value": tc.value}, nil); err == nil {
				t.Fatalf("Validate accepted value above the %d-byte default", defaultMaxStringBytes)
			}
		})
	}

	override := defaultMaxStringBytes + 10
	arg := actionspec.Arg{
		Name: "value", Type: actionspec.ArgString,
		Validation: &actionspec.Validation{MaxLength: &override},
	}
	if _, err := Validate([]actionspec.Arg{arg}, map[string]any{"value": tooLong}, nil); err != nil {
		t.Fatalf("explicit max_length should replace the default: %v", err)
	}
}

func TestValidate_RejectsUnsignedIntegerOverflow(t *testing.T) {
	schema := []actionspec.Arg{{Name: "value", Type: actionspec.ArgInteger}}

	if _, err := Validate(schema, map[string]any{"value": uint64(math.MaxInt64) + 1}, nil); err == nil {
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
			if _, err := Validate(schema, map[string]any{"value": value}, nil); err == nil {
				t.Fatalf("Validate accepted non-finite value %#v", value)
			}
		})
	}
}
