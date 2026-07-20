// Package outputschema compiles and validates opt-in structured action results.
package outputschema

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"

	"github.com/andrewdryga/emisar/runner/internal/jsonvalue"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const (
	MaxSchemaBytes = 8 << 10
	MaxResultBytes = 8 << 10
	MaxSchemaDepth = 16
	MaxSchemaNodes = 512
	MaxResultDepth = 16
	MaxResultNodes = 1024

	// A bounded literal keeps big.Rat comparisons inside the schema library
	// cheap: 1e-1000000000 would otherwise expand into a ~400 MB denominator.
	maxNumberLiteralBytes   = 64
	maxNumberExponentDigits = 3

	schemaURL    = "urn:emisar:output-schema"
	draft2020URL = "https://json-schema.org/draft/2020-12/schema"
)

var (
	schemaLimits = jsonvalue.Limits{
		MaxBytes: MaxSchemaBytes,
		MaxDepth: MaxSchemaDepth,
		MaxNodes: MaxSchemaNodes,
	}
	resultLimits = jsonvalue.Limits{
		MaxBytes: MaxResultBytes,
		MaxDepth: MaxResultDepth,
		MaxNodes: MaxResultNodes,
	}
)

// Validator is the compiled result contract cached beside its loaded action.
type Validator struct {
	value *jsonschema.Schema
}

// Error is a stable, non-sensitive failure safe to return to the control
// plane. Library validation errors can contain instance values and stay local.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

// Compile validates one declared contract and compiles the schema once at pack
// load time. It returns the normalized schema the caller must advertise. A nil
// validator means the action did not opt into structured results.
func Compile(actionID string, output actionspec.Output) (*Validator, map[string]any, error) {
	if output.Schema == nil {
		return nil, nil, nil
	}
	if output.Schema["type"] != "object" {
		return nil, nil, fmt.Errorf("action %s: output.schema root type must be object", actionID)
	}

	// The one YAML→JSON conversion point. yaml.v3 hands the loader Go ints and
	// float64s; marshaling and re-decoding with UseNumber turns them into the
	// canonical JSON literals every consumer sees, and into json.Number so
	// const/enum compare as exact decimals against result values, which decode
	// the same way. Compiling anything else would validate a different contract
	// than the descriptor advertises.
	raw, err := json.Marshal(output.Schema)
	if err != nil {
		return nil, nil, fmt.Errorf("action %s: invalid output.schema: %w", actionID, err)
	}
	if err := jsonvalue.Validate(raw, schemaLimits); err != nil {
		return nil, nil, fmt.Errorf("action %s: invalid output.schema: %w", actionID, err)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var normalized map[string]any
	if err := decoder.Decode(&normalized); err != nil {
		return nil, nil, fmt.Errorf("action %s: decode output.schema: %w", actionID, err)
	}
	if err := validateKeywords(normalized, true); err != nil {
		return nil, nil, fmt.Errorf("action %s: invalid output.schema: %w", actionID, err)
	}
	if err := lintNumbers(normalized); err != nil {
		return nil, nil, fmt.Errorf("action %s: invalid output.schema: %w", actionID, err)
	}

	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	compiler.UseLoader(denyLoader{})
	if err := compiler.AddResource(schemaURL, normalized); err != nil {
		return nil, nil, fmt.Errorf("action %s: load output.schema: %w", actionID, err)
	}
	compiled, err := compiler.Compile(schemaURL)
	if err != nil {
		return nil, nil, fmt.Errorf("action %s: compile output.schema: %w", actionID, err)
	}
	return &Validator{value: compiled}, normalized, nil
}

// Validate strictly decodes a redacted stdout object, validates it, and
// returns both its parsed value and the exact bounded bytes used on the wire.
func (v *Validator) Validate(raw []byte) (map[string]any, json.RawMessage, *Error) {
	value, err := jsonvalue.DecodeObject(raw, resultLimits)
	if err != nil {
		switch {
		case errors.Is(err, jsonvalue.ErrTooLarge):
			return nil, nil, outputError("output_too_large", "structured output exceeds 8192 bytes")
		case errors.Is(err, jsonvalue.ErrTooDeep), errors.Is(err, jsonvalue.ErrTooManyNodes):
			return nil, nil, outputError("output_too_complex", "structured output exceeds complexity limits")
		default:
			return nil, nil, outputError("output_invalid_json", "structured output must be one valid JSON object")
		}
	}
	if v == nil || v.value == nil {
		return nil, nil, outputError("output_schema_unavailable", "structured output schema is unavailable")
	}
	if !boundedNumbers(value) {
		return nil, nil, outputError("output_too_complex", "structured output contains an oversized JSON number")
	}
	if err := v.value.Validate(value); err != nil {
		return nil, nil, outputError("output_schema_mismatch", "structured output does not match its declared schema")
	}

	// SetEscapeHTML(false) keeps `<`, `>`, and `&` at their wire size, so a
	// legitimate result full of them cannot outgrow its already-bounded source.
	// Only U+2028/U+2029 and rare control escapes still encode longer than they
	// arrived, so the wire bound is re-checked once after encoding.
	var canonical bytes.Buffer
	encoder := json.NewEncoder(&canonical)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, nil, outputError("output_invalid_json", "structured output must be one valid JSON object")
	}
	encoded := bytes.TrimSuffix(canonical.Bytes(), []byte("\n"))
	if len(encoded) > MaxResultBytes {
		return nil, nil, outputError("output_too_large", "structured output exceeds 8192 bytes after canonical encoding")
	}
	return value, json.RawMessage(encoded), nil
}

func outputError(code, message string) *Error { return &Error{Code: code, Message: message} }

type denyLoader struct{}

func (denyLoader) Load(url string) (any, error) {
	return nil, fmt.Errorf("external schema resource %q is disabled", url)
}

var localRefPattern = regexp.MustCompile(`^#/\$defs/[A-Za-z0-9._-]+$`)

func validateKeywords(value any, root bool) error {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			switch key {
			case "$schema":
				if !root || child != draft2020URL {
					return fmt.Errorf("$schema must be the root Draft 2020-12 URI")
				}
			case "$ref":
				ref, ok := child.(string)
				if !ok || !localRefPattern.MatchString(ref) {
					return fmt.Errorf("$ref must name one direct $defs entry")
				}
			case "$id", "$anchor", "$dynamicAnchor", "$dynamicRef", "$recursiveRef", "$vocabulary",
				"definitions", "contentEncoding", "contentMediaType", "contentSchema":
				return fmt.Errorf("keyword %s is not allowed", key)
			}
			if err := validateKeywords(child, false); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := validateKeywords(child, false); err != nil {
				return err
			}
		}
	}
	return nil
}

// lintNumbers enforces the float64-canonical authoring contract: every numeric
// literal must survive the float64 round trip that other consumers (the
// portal, JS/LLM clients) apply, and multipleOf stays a positive integer so
// its rational-modulo semantics are exact. Failures surface to pack authors at
// catalog build and pack load.
func lintNumbers(value any) error {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if number, ok := child.(json.Number); ok && key == "multipleOf" {
				if factor, err := strconv.ParseInt(number.String(), 10, 64); err != nil || factor <= 0 {
					return fmt.Errorf("multipleOf %s must be a positive integer", number)
				}
			}
			if err := lintNumbers(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := lintNumbers(child); err != nil {
				return err
			}
		}
	case json.Number:
		return checkFloat64Canonical(value.String())
	}
	return nil
}

func checkFloat64Canonical(literal string) error {
	if !boundedNumberLiteral(literal) {
		return fmt.Errorf("number %s exceeds the literal size limit", literal)
	}
	parsed, err := strconv.ParseFloat(literal, 64)
	if err != nil {
		return fmt.Errorf("number %s does not fit float64", literal)
	}
	if canonical := strconv.FormatFloat(parsed, 'g', -1, 64); !sameDecimal(literal, canonical) {
		return fmt.Errorf("number %s does not survive the float64 round trip; write %s", literal, canonical)
	}
	return nil
}

func boundedNumbers(value any) bool {
	switch value := value.(type) {
	case json.Number:
		return boundedNumberLiteral(value.String())
	case map[string]any:
		for _, child := range value {
			if !boundedNumbers(child) {
				return false
			}
		}
	case []any:
		for _, child := range value {
			if !boundedNumbers(child) {
				return false
			}
		}
	}
	return true
}

func boundedNumberLiteral(literal string) bool {
	if len(literal) > maxNumberLiteralBytes {
		return false
	}
	if i := strings.IndexAny(literal, "eE"); i >= 0 {
		if exponent := strings.TrimLeft(literal[i+1:], "+-"); len(exponent) > maxNumberExponentDigits {
			return false
		}
	}
	return true
}

// sameDecimal compares two number literals as exact decimal values, so
// equivalent spellings (1e3, 1000, 1000.0) all count as one canonical number.
func sameDecimal(a, b string) bool {
	aNegative, aDigits, aExponent, ok := decimalParts(a)
	if !ok {
		return false
	}
	bNegative, bDigits, bExponent, ok := decimalParts(b)
	if !ok {
		return false
	}
	if aDigits == "" || bDigits == "" {
		return aDigits == bDigits // zero is zero regardless of sign or exponent
	}
	return aNegative == bNegative && aDigits == bDigits && aExponent == bExponent
}

// decimalParts normalizes a bounded literal to sign, digits × 10^exponent,
// with no leading or trailing zeros left in digits.
func decimalParts(literal string) (negative bool, digits string, exponent int, ok bool) {
	rest := strings.TrimPrefix(literal, "-")
	negative = rest != literal
	mantissa := rest
	if i := strings.IndexAny(rest, "eE"); i >= 0 {
		mantissa = rest[:i]
		parsed, err := strconv.Atoi(strings.TrimPrefix(rest[i+1:], "+"))
		if err != nil {
			return false, "", 0, false
		}
		exponent = parsed
	}
	if i := strings.IndexByte(mantissa, '.'); i >= 0 {
		exponent -= len(mantissa) - i - 1
		mantissa = mantissa[:i] + mantissa[i+1:]
	}
	digits = strings.TrimLeft(mantissa, "0")
	if digits == "" {
		return negative, "", 0, true
	}
	trimmed := strings.TrimRight(digits, "0")
	exponent += len(digits) - len(trimmed)
	return negative, trimmed, exponent, true
}
