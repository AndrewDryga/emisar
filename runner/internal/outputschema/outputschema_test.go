package outputschema

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func validSchema() map[string]any {
	return map[string]any{
		"$schema": draft2020URL,
		"type":    "object",
		"$defs": map[string]any{
			"name": map[string]any{"type": "string", "minLength": 1},
		},
		"properties": map[string]any{
			"name":  map[string]any{"$ref": "#/$defs/name"},
			"count": map[string]any{"type": "integer"},
		},
		"required":             []any{"name", "count"},
		"additionalProperties": false,
	}
}

func output(schema map[string]any) actionspec.Output {
	return actionspec.Output{Parser: actionspec.ParserJSON, ParserRequired: true, Schema: schema}
}

func compile(t *testing.T, schema map[string]any) *Validator {
	t.Helper()
	validator, _, err := Compile("test.typed", output(schema))
	if err != nil {
		t.Fatal(err)
	}
	return validator
}

func TestCompileAndValidate(t *testing.T) {
	validator := compile(t, validSchema())
	got, raw, outputErr := validator.Validate([]byte(`{"name":"alice","count":9007199254740993}`))
	if outputErr != nil {
		t.Fatal(outputErr)
	}
	if got["count"].(interface{ String() string }).String() != "9007199254740993" {
		t.Fatalf("integer lost precision: %#v", got["count"])
	}
	if string(raw) != `{"count":9007199254740993,"name":"alice"}` {
		t.Fatalf("canonical result = %s", raw)
	}

	for _, tc := range []struct {
		name string
		raw  string
		code string
	}{
		{"schema mismatch", `{"name":"alice","count":"two"}`, "output_schema_mismatch"},
		{"duplicate key", `{"name":"alice","name":"bob","count":2}`, "output_invalid_json"},
		{"non-object", `[]`, "output_invalid_json"},
		{"too large", `{"name":"` + strings.Repeat("x", MaxResultBytes) + `","count":2}`, "output_too_large"},
		{"too deep", strings.Repeat(`{"next":`, MaxResultDepth) + `{}` + strings.Repeat(`}`, MaxResultDepth), "output_too_complex"},
		{"too many nodes", `{"name":"alice","count":2,"values":[` + strings.Repeat(`0,`, MaxResultNodes) + `0]}`, "output_too_complex"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := validator.Validate([]byte(tc.raw)); err == nil || err.Code != tc.code {
				t.Fatalf("error=%v, want code %q", err, tc.code)
			}
		})
	}
}

func TestCompileReturnsNormalizedSchema(t *testing.T) {
	_, normalized, err := Compile("test.typed", output(map[string]any{
		"type":       "object",
		"properties": map[string]any{"ratio": map[string]any{"const": 0.5, "maximum": 2}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	ratio := normalized["properties"].(map[string]any)["ratio"].(map[string]any)
	if got, ok := ratio["const"].(json.Number); !ok || got.String() != "0.5" {
		t.Fatalf("const = %#v, want json.Number 0.5", ratio["const"])
	}
	if got, ok := ratio["maximum"].(json.Number); !ok || got.String() != "2" {
		t.Fatalf("maximum = %#v, want json.Number 2", ratio["maximum"])
	}
}

func TestValidateKeepsAngleBracketsRaw(t *testing.T) {
	validator := compile(t, map[string]any{
		"type":       "object",
		"properties": map[string]any{"value": map[string]any{"type": "string"}},
	})
	// This wire-legal payload used to fail output_too_large because HTML
	// escaping tripled every angle bracket in the canonical encoding.
	raw := []byte(`{"value":"` + strings.Repeat("<", 1_365) + `>&"}`)
	if len(raw) > MaxResultBytes {
		t.Fatalf("test input is already over source bound: %d", len(raw))
	}
	_, canonical, err := validator.Validate(raw)
	if err != nil {
		t.Fatalf("angle-bracket result rejected: %v", err)
	}
	if string(canonical) != string(raw) {
		t.Fatalf("canonical encoding rewrote the value: %s", canonical)
	}
}

func TestValidateRejectsCanonicalExpansionPastWireLimit(t *testing.T) {
	validator := compile(t, map[string]any{
		"type":       "object",
		"properties": map[string]any{"value": map[string]any{"type": "string"}},
	})
	// U+2028 arrives as three raw bytes but canonically encodes as a six-byte
	// escape — the one remaining way the canonical form can outgrow its source.
	raw := []byte(`{"value":"` + strings.Repeat("\u2028", 1_365) + `"}`)
	if len(raw) > MaxResultBytes {
		t.Fatalf("test input is already over source bound: %d", len(raw))
	}
	if _, _, got := validator.Validate(raw); got == nil || got.Code != "output_too_large" {
		t.Fatalf("error=%v, want canonical output_too_large", got)
	}
}

func TestCompileRejectsUnsafeContracts(t *testing.T) {
	deepSchema := map[string]any{"type": "string"}
	for range MaxSchemaDepth {
		deepSchema = map[string]any{"allOf": []any{deepSchema}}
	}

	cases := []struct {
		name   string
		schema map[string]any
	}{
		{"non-object root", map[string]any{"type": "array"}},
		{"external ref", map[string]any{"type": "object", "$ref": "https://example.com/schema"}},
		{"relative ref", map[string]any{"type": "object", "$ref": "other.json"}},
		{"root ref", map[string]any{"type": "object", "$ref": "#"}},
		{"nested local ref", map[string]any{"type": "object", "$ref": "#/$defs/value/properties/x", "$defs": map[string]any{"value": map[string]any{"type": "object"}}}},
		{"identity", map[string]any{"type": "object", "$id": "urn:other"}},
		{"dynamic ref", map[string]any{"type": "object", "$dynamicRef": "#/x"}},
		{"legacy definitions", map[string]any{"type": "object", "definitions": map[string]any{"value": map[string]any{"type": "string"}}}},
		{"nested dialect", map[string]any{"type": "object", "properties": map[string]any{"x": map[string]any{"$schema": draft2020URL}}}},
		{"invalid keyword value", map[string]any{"type": "object", "required": "name"}},
		{"dangling local ref", map[string]any{"type": "object", "$ref": "#/$defs/missing"}},
		{"huge exponent", map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"const": json.Number("1e-1000000000")}}}},
		{"oversize", map[string]any{"type": "object", "description": strings.Repeat("x", MaxSchemaBytes)}},
		{"too deep", map[string]any{"type": "object", "properties": map[string]any{"value": deepSchema}}},
		{"too many nodes", map[string]any{"type": "object", "enum": repeatedValues(MaxSchemaNodes)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := Compile("test.typed", output(tc.schema)); err == nil {
				t.Fatal("unsafe schema accepted")
			}
		})
	}
}

func TestCompileAllowsBoundedRecursion(t *testing.T) {
	// A $defs cycle is safe: the jsonschema compiler resolves it and result
	// decoding is already bounded, so validation cannot recurse past the
	// instance limits.
	validator := compile(t, map[string]any{
		"type":       "object",
		"properties": map[string]any{"root": map[string]any{"$ref": "#/$defs/node"}},
		"$defs": map[string]any{"node": map[string]any{
			"type":                 "object",
			"additionalProperties": false,
			"properties":           map[string]any{"next": map[string]any{"$ref": "#/$defs/node"}},
		}},
	})
	if _, _, err := validator.Validate([]byte(`{"root":{"next":{"next":{}}}}`)); err != nil {
		t.Fatalf("bounded recursive result rejected: %v", err)
	}
	deep := `{"root":` + strings.Repeat(`{"next":`, MaxResultDepth) + `{}` + strings.Repeat(`}`, MaxResultDepth) + `}`
	if _, _, err := validator.Validate([]byte(deep)); err == nil || err.Code != "output_too_complex" {
		t.Fatalf("error=%v, want output_too_complex", err)
	}
}

func TestCompileLintsNumericLiterals(t *testing.T) {
	cases := []struct {
		name    string
		keyword string
		literal any
		wantErr string
	}{
		{"integer multipleOf", "multipleOf", json.Number("2"), ""},
		{"fractional multipleOf", "multipleOf", json.Number("0.1"), "positive integer"},
		{"zero multipleOf", "multipleOf", json.Number("0"), "positive integer"},
		{"negative multipleOf", "multipleOf", json.Number("-2"), "positive integer"},
		{"exact decimal", "const", json.Number("0.1"), ""},
		{"equivalent spelling", "maximum", json.Number("1e3"), ""},
		{"two to the 53", "const", json.Number("9007199254740992"), ""},
		{"unrepresentable integer", "const", json.Number("9007199254740993"), "float64 round trip"},
		{"seventeen-digit decimal", "const", json.Number("0.10000000000000001"), "float64 round trip"},
		{"overflow", "minimum", json.Number("1e999"), "does not fit float64"},
		{"underflow", "const", json.Number("1e-999"), "float64 round trip"},
		{"oversized exponent", "const", json.Number("1e-1000000000"), "literal size limit"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			schema := map[string]any{
				"type":       "object",
				"properties": map[string]any{"value": map[string]any{tc.keyword: tc.literal}},
			}
			_, _, err := Compile("test.typed", output(schema))
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("canonical literal rejected: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error=%v, want substring %q", err, tc.wantErr)
			}
		})
	}
}

func TestValidateBoundsResultNumbers(t *testing.T) {
	validator := compile(t, map[string]any{
		"type":       "object",
		"properties": map[string]any{"value": map[string]any{"type": "number"}},
	})
	if _, _, err := validator.Validate([]byte(`{"value":1e999}`)); err != nil {
		t.Fatalf("bounded literal rejected: %v", err)
	}
	for _, tc := range []struct {
		name string
		raw  string
	}{
		{"huge exponent", `{"value":1e-1000000000}`},
		{"oversized literal", `{"value":` + strings.Repeat("9", maxNumberLiteralBytes+1) + `}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := validator.Validate([]byte(tc.raw)); err == nil || err.Code != "output_too_complex" {
				t.Fatalf("error=%v, want output_too_complex", err)
			}
		})
	}
}

func TestValidateComparesDecimalsExactly(t *testing.T) {
	validator := compile(t, map[string]any{
		"type":       "object",
		"properties": map[string]any{"value": map[string]any{"const": json.Number("0.1")}},
	})
	if _, _, err := validator.Validate([]byte(`{"value":0.1}`)); err != nil {
		t.Fatalf("exact decimal rejected: %v", err)
	}
	if _, _, err := validator.Validate([]byte(`{"value":0.10000000000000001}`)); err == nil || err.Code != "output_schema_mismatch" {
		t.Fatalf("adjacent decimal error=%v, want output_schema_mismatch", err)
	}
}

func repeatedValues(count int) []any {
	values := make([]any, count)
	for i := range values {
		values[i] = i
	}
	return values
}
