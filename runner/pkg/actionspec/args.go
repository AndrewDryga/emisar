package actionspec

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"time"

	"gopkg.in/yaml.v3"
)

// ArgType is the declared argument type for an action or runbook input.
type ArgType string

const (
	ArgString       ArgType = "string"
	ArgInteger      ArgType = "integer"
	ArgNumber       ArgType = "number"
	ArgBoolean      ArgType = "boolean"
	ArgDuration     ArgType = "duration"
	ArgPath         ArgType = "path"
	ArgStringArray  ArgType = "string_array"
	ArgIntegerArray ArgType = "integer_array"
)

// Valid reports whether t is a supported arg type.
func (t ArgType) Valid() bool {
	switch t {
	case ArgString, ArgInteger, ArgNumber, ArgBoolean,
		ArgDuration, ArgPath, ArgStringArray, ArgIntegerArray:
		return true
	}
	return false
}

// Arg is the declared schema for a single named argument.
//
// Setting `sensitive: true` makes the runner treat the supplied value as
// a secret: it will be replaced with `[REDACTED]` everywhere it would
// otherwise appear (local JSONL audit, cloud event payloads). Use this
// for tokens, passwords, DSNs containing credentials, customer PII.
type Arg struct {
	Name        string      `yaml:"name" json:"name"`
	Type        ArgType     `yaml:"type" json:"type"`
	Required    bool        `yaml:"required" json:"required"`
	Sensitive   bool        `yaml:"sensitive,omitempty" json:"sensitive,omitempty"`
	Default     any         `yaml:"default,omitempty" json:"default,omitempty"`
	Description string      `yaml:"description,omitempty" json:"description,omitempty"`
	Validation  *Validation `yaml:"validation,omitempty" json:"validation,omitempty"`
}

// Validation are the optional constraints applied to an argument value after
// type coercion.
type Validation struct {
	Enum            []any    `yaml:"enum,omitempty" json:"enum,omitempty"`
	Pattern         string   `yaml:"pattern,omitempty" json:"pattern,omitempty"`
	Min             *float64 `yaml:"min,omitempty" json:"min,omitempty"`
	Max             *float64 `yaml:"max,omitempty" json:"max,omitempty"`
	Allowed         []any    `yaml:"allowed,omitempty" json:"allowed,omitempty"`
	AllowedPaths    []string `yaml:"allowed_paths,omitempty" json:"allowed_paths,omitempty"`
	DeniedPaths     []string `yaml:"denied_paths,omitempty" json:"denied_paths,omitempty"`
	AllowedPrefixes []string `yaml:"allowed_prefixes,omitempty" json:"allowed_prefixes,omitempty"`
	DeniedPrefixes  []string `yaml:"denied_prefixes,omitempty" json:"denied_prefixes,omitempty"`
	MaxItems        *int     `yaml:"max_items,omitempty" json:"max_items,omitempty"`
	// MaxLength caps a string/path value (or each element of a string_array)
	// at this many BYTES. Unset uses the runner's conservative 32 KiB per-value
	// default; actions should set a smaller domain-specific limit where useful.
	MaxLength   *int      `yaml:"max_length,omitempty" json:"max_length,omitempty"`
	MinDuration *Duration `yaml:"min_duration,omitempty" json:"min_duration,omitempty"`
	MaxDuration *Duration `yaml:"max_duration,omitempty" json:"max_duration,omitempty"`
}

// Validate checks that the arg declaration itself is well-formed (it does
// not validate any concrete value — see internal/validation for that).
func (a Arg) Validate() error {
	if a.Name == "" {
		return fmt.Errorf("arg has empty name")
	}
	if !a.Type.Valid() {
		return fmt.Errorf("arg %s: invalid type %q", a.Name, a.Type)
	}
	if a.Required && a.Default != nil {
		return fmt.Errorf("arg %s: required args must not specify default", a.Name)
	}
	if a.Validation != nil {
		if len(a.Validation.Enum) > 0 && len(a.Validation.Allowed) > 0 {
			return fmt.Errorf("arg %s: validation.enum and validation.allowed cannot both be set", a.Name)
		}
		for _, membership := range []struct {
			name   string
			values []any
		}{
			{name: "enum", values: a.Validation.Enum},
			{name: "allowed", values: a.Validation.Allowed},
		} {
			if err := validateMembershipCandidates(a.Type, membership.name, membership.values); err != nil {
				return fmt.Errorf("arg %s: %w", a.Name, err)
			}
		}
	}
	// Compile the pattern here so an uncompilable regex fails `pack validate`
	// at authoring time, not at execution. The runtime validator (which
	// rejects the arg) uses the same regexp engine, and Go caps a repeat
	// bound at 1000 — e.g. `.{0,2048}` is a compile error, so without this
	// check such an action loads fine yet can never run.
	if a.Validation != nil && a.Validation.Pattern != "" {
		// A pattern only matches string-ish values; on a numeric/boolean/array
		// arg the runtime validator rejects it on every dispatch, so the action
		// would load yet be permanently unrunnable. Catch it at authoring time.
		if a.Type != ArgString && a.Type != ArgPath {
			return fmt.Errorf("arg %s: validation.pattern is only valid on string/path args, not %q", a.Name, a.Type)
		}

		if _, err := regexp.Compile(a.Validation.Pattern); err != nil {
			return fmt.Errorf("arg %s: invalid validation.pattern %q: %w", a.Name, a.Validation.Pattern, err)
		}
	}
	// max_length only bounds string-ish values; on a numeric/boolean/integer_array
	// arg the runtime validator can't apply it, so the action would load yet be
	// misleadingly "bounded". Reject at authoring time, and require a positive cap.
	if a.Validation != nil && a.Validation.MaxLength != nil {
		if a.Type != ArgString && a.Type != ArgPath && a.Type != ArgStringArray {
			return fmt.Errorf("arg %s: validation.max_length is only valid on string/path/string_array args, not %q", a.Name, a.Type)
		}
		if *a.Validation.MaxLength <= 0 {
			return fmt.Errorf("arg %s: validation.max_length must be positive, got %d", a.Name, *a.Validation.MaxLength)
		}
	}
	if a.Validation != nil && (a.Validation.Min != nil || a.Validation.Max != nil) {
		if a.Type != ArgInteger && a.Type != ArgIntegerArray && a.Type != ArgNumber {
			return fmt.Errorf("arg %s: validation.min/max is only valid on numeric args, not %q", a.Name, a.Type)
		}
		for _, bound := range []struct {
			name  string
			value *float64
		}{
			{name: "min", value: a.Validation.Min},
			{name: "max", value: a.Validation.Max},
		} {
			if bound.value == nil {
				continue
			}
			if math.IsNaN(*bound.value) || math.IsInf(*bound.value, 0) {
				return fmt.Errorf("arg %s: validation.%s must be finite", a.Name, bound.name)
			}
			if (a.Type == ArgInteger || a.Type == ArgIntegerArray) && !validIntegerBound(*bound.value) {
				return fmt.Errorf("arg %s: validation.%s must be an exactly represented integer between -(2^53-1) and 2^53-1", a.Name, bound.name)
			}
		}
		if a.Validation.Min != nil && a.Validation.Max != nil && *a.Validation.Min > *a.Validation.Max {
			return fmt.Errorf("arg %s: validation.min must not exceed validation.max", a.Name)
		}
	}
	if a.Validation != nil && a.Validation.MaxItems != nil {
		if a.Type != ArgStringArray && a.Type != ArgIntegerArray {
			return fmt.Errorf("arg %s: validation.max_items is only valid on array args, not %q", a.Name, a.Type)
		}
		if *a.Validation.MaxItems < 0 {
			return fmt.Errorf("arg %s: validation.max_items must not be negative, got %d", a.Name, *a.Validation.MaxItems)
		}
	}
	if a.Validation != nil && (a.Validation.MinDuration != nil || a.Validation.MaxDuration != nil) {
		if a.Type != ArgDuration {
			return fmt.Errorf("arg %s: validation.min_duration/max_duration is only valid on duration args, not %q", a.Name, a.Type)
		}
		if a.Validation.MinDuration != nil && a.Validation.MaxDuration != nil &&
			a.Validation.MinDuration.Std() > a.Validation.MaxDuration.Std() {
			return fmt.Errorf("arg %s: validation.min_duration must not exceed validation.max_duration", a.Name)
		}
	}
	if a.Validation != nil && hasPathValidation(a.Validation) {
		if a.Type != ArgString && a.Type != ArgPath && a.Type != ArgStringArray {
			return fmt.Errorf("arg %s: path validation is only valid on string/path/string_array args, not %q", a.Name, a.Type)
		}
	}
	return nil
}

func hasPathValidation(validation *Validation) bool {
	return len(validation.AllowedPaths) > 0 || len(validation.DeniedPaths) > 0 ||
		len(validation.AllowedPrefixes) > 0 || len(validation.DeniedPrefixes) > 0
}

func validateMembershipCandidates(argType ArgType, name string, candidates []any) error {
	if len(candidates) == 0 {
		return nil
	}
	if argType == ArgDuration {
		return fmt.Errorf("validation.%s is not supported for duration args", name)
	}

	for index, candidate := range candidates {
		if !membershipCandidateValid(argType, candidate) {
			return fmt.Errorf("validation.%s[%d] has incompatible type %T for %s", name, index, candidate, argType)
		}
	}
	return nil
}

func membershipCandidateValid(argType ArgType, candidate any) bool {
	switch argType {
	case ArgString, ArgPath, ArgStringArray:
		_, ok := candidate.(string)
		return ok
	case ArgInteger, ArgIntegerArray:
		return integerCandidate(candidate)
	case ArgNumber:
		return numberCandidate(candidate)
	case ArgBoolean:
		_, ok := candidate.(bool)
		return ok
	default:
		return false
	}
}

func integerCandidate(candidate any) bool {
	switch number := candidate.(type) {
	case int, int32, int64, uint, uint32:
		return true
	case uint64:
		return number <= math.MaxInt64
	case float32:
		return validIntegerBound(float64(number))
	case float64:
		return validIntegerBound(number)
	default:
		return false
	}
}

func numberCandidate(candidate any) bool {
	switch number := candidate.(type) {
	case int, int32, int64, uint, uint32, uint64:
		return true
	case float32:
		value := float64(number)
		return !math.IsNaN(value) && !math.IsInf(value, 0)
	case float64:
		return !math.IsNaN(number) && !math.IsInf(number, 0)
	default:
		return false
	}
}

func validIntegerBound(bound float64) bool {
	const ambiguousBoundary = float64(1 << 53)

	return math.Trunc(bound) == bound && bound > -ambiguousBoundary && bound < ambiguousBoundary
}

// Duration is time.Duration with YAML string parsing ("30s", "5m", "24h").
type Duration time.Duration

// UnmarshalYAML parses a YAML string into a Duration. Beyond stdlib units it
// also accepts trailing "d" (days) and "w" (weeks) on simple values like
// "7d" or "2w" — these are common in operator-facing config.
func (d *Duration) UnmarshalYAML(node *yaml.Node) error {
	var s string
	if err := node.Decode(&s); err != nil {
		return fmt.Errorf("duration must be a string: %w", err)
	}
	if s == "" {
		*d = 0
		return nil
	}
	parsed, err := parseExtendedDuration(s)
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", s, err)
	}
	*d = Duration(parsed)
	return nil
}

// parseExtendedDuration parses Go's standard duration syntax, extended with
// "d" and "w" suffixes applied to the whole value (e.g., "7d", "2w"). Mixed
// units like "1d12h" are not supported in this small extension — operators
// who need mixed durations can use stdlib units ("36h").
func parseExtendedDuration(s string) (time.Duration, error) {
	if n := len(s); n > 0 {
		var unit time.Duration
		switch s[n-1] {
		case 'd':
			unit = 24 * time.Hour
		case 'w':
			unit = 7 * 24 * time.Hour
		}
		if unit > 0 {
			amount, err := parseLeadingInt(s[:n-1])
			if err != nil {
				return 0, err
			}
			if amount > math.MaxInt64/int64(unit) {
				return 0, fmt.Errorf("duration exceeds maximum %s", time.Duration(math.MaxInt64))
			}
			return time.Duration(amount) * unit, nil
		}
	}
	return time.ParseDuration(s)
}

func parseLeadingInt(s string) (int64, error) {
	if s == "" {
		return 0, fmt.Errorf("empty number")
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("not an integer: %q", s)
		}
	}
	return strconv.ParseInt(s, 10, 64)
}

// MarshalYAML emits the duration as a Go-style duration string.
func (d Duration) MarshalYAML() (any, error) {
	return time.Duration(d).String(), nil
}

// Std returns the standard time.Duration value.
func (d Duration) Std() time.Duration { return time.Duration(d) }

// String returns the standard duration formatting.
func (d Duration) String() string { return time.Duration(d).String() }
