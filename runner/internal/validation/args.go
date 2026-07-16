package validation

import (
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const defaultMaxStringBytes = 32 << 10

// Validate normalizes raw against the arg schema. It returns a new map of
// validated values (only declared args) or a *Error describing the first
// failure. raw must not be mutated.
func Validate(schema []actionspec.Arg, raw map[string]any) (map[string]any, error) {
	if raw == nil {
		raw = map[string]any{}
	}
	out := make(map[string]any, len(schema))
	known := make(map[string]struct{}, len(schema))
	for _, a := range schema {
		known[a.Name] = struct{}{}
	}
	for name := range raw {
		if _, ok := known[name]; !ok {
			return nil, newError(name, "unknown_arg", "unknown argument")
		}
	}
	for _, a := range schema {
		v, present := raw[a.Name]
		if !present {
			if a.Required {
				return nil, newError(a.Name, "required", "is required")
			}
			if a.Default != nil {
				v = a.Default
			} else {
				continue
			}
		}
		coerced, err := coerce(a, v)
		if err != nil {
			return nil, err
		}
		if err := applyValidation(a, coerced); err != nil {
			return nil, err
		}
		out[a.Name] = coerced
	}
	return out, nil
}

func coerce(a actionspec.Arg, v any) (any, error) {
	switch a.Type {
	case actionspec.ArgString, actionspec.ArgPath:
		s, ok := toString(v)
		if !ok {
			return nil, newError(a.Name, "type", "expected string")
		}
		if a.Type == actionspec.ArgPath {
			s = filepath.Clean(s)
		}
		return s, nil
	case actionspec.ArgInteger:
		n, ok := toInt(v)
		if !ok {
			return nil, newError(a.Name, "type", "expected integer")
		}
		return n, nil
	case actionspec.ArgNumber:
		if number, ok := v.(json.Number); ok {
			if _, valid := toFloat(number); !valid {
				return nil, newError(a.Name, "type", "expected number")
			}
			return number, nil
		}
		n, ok := toFloat(v)
		if !ok {
			return nil, newError(a.Name, "type", "expected number")
		}
		return n, nil
	case actionspec.ArgBoolean:
		b, ok := v.(bool)
		if !ok {
			return nil, newError(a.Name, "type", "expected boolean")
		}
		return b, nil
	case actionspec.ArgDuration:
		s, ok := toString(v)
		if !ok {
			return nil, newError(a.Name, "type", "expected duration string")
		}
		d, err := time.ParseDuration(s)
		if err != nil {
			return nil, newError(a.Name, "type", "invalid duration %q", s)
		}
		return d, nil
	case actionspec.ArgStringArray:
		items, err := toAnyArray(v)
		if err != nil {
			return nil, newError(a.Name, "type", "expected string array")
		}
		out := make([]string, 0, len(items))
		for i, it := range items {
			s, ok := toString(it)
			if !ok {
				return nil, newError(a.Name, "type", "item %d not a string", i)
			}
			out = append(out, s)
		}
		return out, nil
	case actionspec.ArgIntegerArray:
		items, err := toAnyArray(v)
		if err != nil {
			return nil, newError(a.Name, "type", "expected integer array")
		}
		out := make([]int64, 0, len(items))
		for i, it := range items {
			n, ok := toInt(it)
			if !ok {
				return nil, newError(a.Name, "type", "item %d not an integer", i)
			}
			out = append(out, n)
		}
		return out, nil
	}
	return nil, newError(a.Name, "type", "unsupported arg type %q", a.Type)
}

func applyValidation(a actionspec.Arg, v any) error {
	if err := applyStringByteLimit(a, v); err != nil {
		return err
	}
	if a.Validation == nil {
		return nil
	}
	val := a.Validation

	// Arrays apply max_items at array scope, scalar validators per-element.
	if isArrayType(a.Type) {
		if val.MaxItems != nil {
			n, ok := arrayLen(v)
			if !ok {
				return newError(a.Name, "max_items", "requires array value")
			}
			if n > *val.MaxItems {
				return newError(a.Name, "max_items", "too many items (max %d)", *val.MaxItems)
			}
		}
		elements, err := elementsOf(v)
		if err != nil {
			return newError(a.Name, "type", "%s", err.Error())
		}
		for i, elem := range elements {
			if err := applyScalarValidators(a, val, elem); err != nil {
				return wrapElementError(err, i)
			}
		}
		return applyPathValidation(a, val, v)
	}

	if err := applyScalarValidators(a, val, v); err != nil {
		return err
	}
	if val.MaxItems != nil {
		// max_items on a non-array arg: schema bug, but be explicit.
		return newError(a.Name, "max_items", "requires array value")
	}
	return applyPathValidation(a, val, v)
}

func applyStringByteLimit(a actionspec.Arg, v any) error {
	if a.Type != actionspec.ArgString && a.Type != actionspec.ArgPath && a.Type != actionspec.ArgStringArray {
		return nil
	}
	limit := defaultMaxStringBytes
	if a.Validation != nil && a.Validation.MaxLength != nil {
		limit = *a.Validation.MaxLength
	}
	values, err := stringsFor(a, v)
	if err != nil {
		return err
	}
	for i, value := range values {
		if len(value) <= limit {
			continue
		}
		err := newError(a.Name, "max_length", "must be at most %d bytes (got %d)", limit, len(value))
		if a.Type == actionspec.ArgStringArray {
			return wrapElementError(err, i)
		}
		return err
	}
	return nil
}

// applyScalarValidators runs validators that meaningfully apply to a
// single value (enum, pattern, min/max, durations).
func applyScalarValidators(a actionspec.Arg, val *actionspec.Validation, v any) error {
	if len(val.Enum) > 0 {
		if !inAnyList(v, val.Enum) {
			return newError(a.Name, "enum", "value must be one of %v", val.Enum)
		}
	}
	if len(val.Allowed) > 0 {
		if !inAnyList(v, val.Allowed) {
			return newError(a.Name, "allowed", "value must be one of %v", val.Allowed)
		}
	}
	if val.Pattern != "" {
		s, ok := v.(string)
		if !ok {
			return newError(a.Name, "type", "pattern requires string value")
		}
		re, err := regexp.Compile(val.Pattern)
		if err != nil {
			return newError(a.Name, "pattern", "invalid regex in schema: %v", err)
		}
		if !re.MatchString(s) {
			return newError(a.Name, "pattern", "must match pattern %s", val.Pattern)
		}
	}
	if val.Min != nil {
		below, ok := belowNumericBound(v, *val.Min)
		if !ok {
			return newError(a.Name, "min", "min requires numeric value")
		}
		if below {
			return newError(a.Name, "min", "must be >= %v", *val.Min)
		}
	}
	if val.Max != nil {
		above, ok := aboveNumericBound(v, *val.Max)
		if !ok {
			return newError(a.Name, "max", "max requires numeric value")
		}
		if above {
			return newError(a.Name, "max", "must be <= %v", *val.Max)
		}
	}
	if val.MinDuration != nil {
		d, ok := v.(time.Duration)
		if !ok {
			return newError(a.Name, "min_duration", "requires duration value")
		}
		if d < val.MinDuration.Std() {
			return newError(a.Name, "min_duration", "must be >= %s", val.MinDuration.Std())
		}
	}
	if val.MaxDuration != nil {
		d, ok := v.(time.Duration)
		if !ok {
			return newError(a.Name, "max_duration", "requires duration value")
		}
		if d > val.MaxDuration.Std() {
			return newError(a.Name, "max_duration", "must be <= %s", val.MaxDuration.Std())
		}
	}
	return nil
}

func belowNumericBound(value any, bound float64) (bool, bool) {
	comparison, ok := compareNumeric(value, bound)
	return ok && comparison < 0, ok
}

func aboveNumericBound(value any, bound float64) (bool, bool) {
	comparison, ok := compareNumeric(value, bound)
	return ok && comparison > 0, ok
}

// applyPathValidation runs path allow/deny rules. Works on string and
// []string values via stringsFor.
func applyPathValidation(a actionspec.Arg, val *actionspec.Validation, v any) error {
	if len(val.AllowedPaths) == 0 && len(val.DeniedPaths) == 0 &&
		len(val.AllowedPrefixes) == 0 && len(val.DeniedPrefixes) == 0 {
		return nil
	}
	strs, err := stringsFor(a, v)
	if err != nil {
		return err
	}
	// Resolve allow/deny lists too so an author writing /var/log on a
	// host where /var → /private/var still gets a matching comparison
	// against an input that resolves to /private/var/log/...
	allowedPaths, err := resolveMany(val.AllowedPaths)
	if err != nil {
		return newError(a.Name, "path", "cannot safely resolve allowed_paths: %v", err)
	}
	deniedPaths, err := resolveMany(val.DeniedPaths)
	if err != nil {
		return newError(a.Name, "path", "cannot safely resolve denied_paths: %v", err)
	}
	allowedPrefixes, err := resolveMany(val.AllowedPrefixes)
	if err != nil {
		return newError(a.Name, "path", "cannot safely resolve allowed_prefixes: %v", err)
	}
	deniedPrefixes, err := resolveMany(val.DeniedPrefixes)
	if err != nil {
		return newError(a.Name, "path", "cannot safely resolve denied_prefixes: %v", err)
	}

	for _, s := range strs {
		resolved, err := resolveForCheck(s)
		if err != nil {
			return newError(a.Name, "path", "cannot safely resolve path %s: %v", s, err)
		}
		// A relative value never matches an absolute allow/deny list, so it
		// would slip past the deny checks below and then be run by the
		// executor under its CWD — resolving to a denied absolute path. Path
		// rules only make sense against the absolute path the executor uses,
		// so require one.
		if !filepath.IsAbs(resolved) {
			return newError(a.Name, "path", "path %s must be absolute", resolved)
		}
		if len(allowedPaths) > 0 && !pathInList(resolved, allowedPaths) {
			return newError(a.Name, "allowed_paths", "path %s not in allowlist", resolved)
		}
		if pathInList(resolved, deniedPaths) {
			return newError(a.Name, "denied_paths", "path %s is denied", resolved)
		}
		if len(allowedPrefixes) > 0 && !prefixInList(resolved, allowedPrefixes) {
			return newError(a.Name, "allowed_prefixes", "path %s not in allowed prefixes", resolved)
		}
		if prefixInList(resolved, deniedPrefixes) {
			return newError(a.Name, "denied_prefixes", "path %s under denied prefix", resolved)
		}
	}
	return nil
}

func resolveMany(in []string) ([]string, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(in))
	for _, p := range in {
		resolved, err := resolveForCheck(p)
		if err != nil {
			return nil, fmt.Errorf("%q: %w", p, err)
		}
		out = append(out, resolved)
	}
	return out, nil
}

// resolveForCheck cleans p and resolves symlinks, even when the leaf
// doesn't exist yet. It walks up to the deepest existing parent,
// EvalSymlinks-resolves it, and re-attaches the missing tail. This
// blocks the attack where /var/log/<symlink>/foo points to /etc/foo
// before /etc/foo exists: the symlinked parent resolves to /etc, and
// the resulting /etc/foo fails any allowed_prefixes check pinned to
// /var/log/.
func resolveForCheck(p string) (string, error) {
	cleaned := filepath.Clean(p)
	if !filepath.IsAbs(cleaned) {
		return cleaned, nil
	}
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return resolved, nil
	}
	// Walk up until we find an existing parent. We may walk all the way
	// to the volume root ("/"); that's fine — its EvalSymlinks is "/".
	tail := ""
	parent := cleaned
	for {
		if _, err := os.Lstat(parent); err == nil {
			resolved, err := filepath.EvalSymlinks(parent)
			if err != nil {
				return "", fmt.Errorf("resolve existing component %q: %w", parent, err)
			}
			return filepath.Clean(filepath.Join(resolved, tail)), nil
		} else if !os.IsNotExist(err) {
			return "", fmt.Errorf("inspect path component %q: %w", parent, err)
		}
		tail = filepath.Join(filepath.Base(parent), tail)
		next := filepath.Dir(parent)
		if next == parent {
			return "", fmt.Errorf("path %q has no resolvable existing component", cleaned)
		}
		parent = next
	}
}

func isArrayType(t actionspec.ArgType) bool {
	return t == actionspec.ArgStringArray || t == actionspec.ArgIntegerArray
}

func elementsOf(v any) ([]any, error) {
	switch arr := v.(type) {
	case []string:
		out := make([]any, len(arr))
		for i, s := range arr {
			out[i] = s
		}
		return out, nil
	case []int64:
		out := make([]any, len(arr))
		for i, n := range arr {
			out[i] = n
		}
		return out, nil
	case []any:
		return arr, nil
	}
	return nil, fmt.Errorf("not an array: %T", v)
}

// wrapElementError prepends "element N: " to a validation error so the
// caller knows which array slot failed.
func wrapElementError(err error, i int) error {
	if e, ok := err.(*Error); ok {
		return &Error{
			Arg:    e.Arg,
			Code:   e.Code,
			Reason: fmt.Sprintf("element %d: %s", i, e.Reason),
		}
	}
	return err
}

func inAnyList(v any, list []any) bool {
	for _, c := range list {
		if equal(v, c) {
			return true
		}
	}
	return false
}

func equal(a, b any) bool {
	switch av := a.(type) {
	case string:
		bs, ok := toString(b)
		return ok && av == bs
	case int64:
		bn, ok := toInt(b)
		return ok && av == bn
	case json.Number:
		comparison, ok := compareNumeric(av, b)
		return ok && comparison == 0
	case float64:
		comparison, ok := compareNumeric(av, b)
		return ok && comparison == 0
	case float32:
		comparison, ok := compareNumeric(av, b)
		return ok && comparison == 0
	case bool:
		bb, ok := b.(bool)
		return ok && av == bb
	}
	return a == b
}

func compareNumeric(a, b any) (int, bool) {
	ar, ok := exactNumeric(a)
	if !ok {
		return 0, false
	}
	br, ok := exactNumeric(b)
	if !ok {
		return 0, false
	}
	return ar.Cmp(br), true
}

func exactNumeric(value any) (*big.Rat, bool) {
	var raw string
	switch number := value.(type) {
	case int:
		raw = strconv.FormatInt(int64(number), 10)
	case int32:
		raw = strconv.FormatInt(int64(number), 10)
	case int64:
		raw = strconv.FormatInt(number, 10)
	case uint:
		raw = strconv.FormatUint(uint64(number), 10)
	case uint32:
		raw = strconv.FormatUint(uint64(number), 10)
	case uint64:
		raw = strconv.FormatUint(number, 10)
	case float32:
		if _, ok := finiteFloat(float64(number)); !ok {
			return nil, false
		}
		raw = strconv.FormatFloat(float64(number), 'g', -1, 32)
	case float64:
		if _, ok := finiteFloat(number); !ok {
			return nil, false
		}
		raw = strconv.FormatFloat(number, 'g', -1, 64)
	case json.Number:
		raw = number.String()
	case string:
		raw = number
	default:
		return nil, false
	}
	rational, ok := new(big.Rat).SetString(raw)
	return rational, ok
}

func arrayLen(v any) (int, bool) {
	switch arr := v.(type) {
	case []string:
		return len(arr), true
	case []int64:
		return len(arr), true
	case []any:
		return len(arr), true
	}
	return 0, false
}

func stringsFor(a actionspec.Arg, v any) ([]string, error) {
	switch s := v.(type) {
	case string:
		return []string{s}, nil
	case []string:
		return s, nil
	}
	return nil, newError(a.Name, "type", "path validation requires string or string array")
}

func pathInList(path string, list []string) bool {
	for _, p := range list {
		if filepath.Clean(p) == path {
			return true
		}
	}
	return false
}

func prefixInList(path string, prefixes []string) bool {
	for _, p := range prefixes {
		clean := filepath.Clean(p)
		// Root covers every absolute path; clean+separator would be "//",
		// which never prefixes a cleaned path, so special-case it.
		if clean == string(filepath.Separator) {
			return true
		}
		if path == clean || strings.HasPrefix(path, clean+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func toString(v any) (string, bool) {
	switch s := v.(type) {
	case string:
		return s, true
	}
	return "", false
}

func toInt(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	case uint:
		if uint64(n) <= math.MaxInt64 {
			return int64(n), true
		}
	case uint32:
		return int64(n), true
	case uint64:
		if n <= math.MaxInt64 {
			return int64(n), true
		}
	case float64:
		if float64(int64(n)) == n {
			return int64(n), true
		}
	case float32:
		if float32(int64(n)) == n {
			return int64(n), true
		}
	case string:
		i, err := strconv.ParseInt(n, 10, 64)
		if err == nil {
			return i, true
		}
	case json.Number:
		return exactJSONInteger(n.String())
	}
	return 0, false
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case int:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case float32:
		return finiteFloat(float64(n))
	case float64:
		return finiteFloat(n)
	case json.Number:
		f, err := n.Float64()
		if err == nil {
			return finiteFloat(f)
		}
	case string:
		f, err := strconv.ParseFloat(n, 64)
		if err == nil {
			return finiteFloat(f)
		}
	}
	return 0, false
}

func finiteFloat(n float64) (float64, bool) {
	return n, !math.IsNaN(n) && !math.IsInf(n, 0)
}

// exactJSONInteger accepts every JSON spelling whose mathematical value is an
// int64 (including 1e3 and 1000.0) without evaluating it through float64.
func exactJSONInteger(raw string) (int64, bool) {
	sign := ""
	if strings.HasPrefix(raw, "-") {
		sign = "-"
		raw = raw[1:]
	}
	mantissa, exponentText, hasExponent := strings.Cut(raw, "e")
	if !hasExponent {
		mantissa, exponentText, hasExponent = strings.Cut(raw, "E")
	}
	exponent := new(big.Int)
	if hasExponent {
		exponentText = strings.TrimPrefix(exponentText, "+")
		if _, ok := exponent.SetString(exponentText, 10); !ok {
			return 0, false
		}
	}
	integer, fraction, _ := strings.Cut(mantissa, ".")
	digits := strings.TrimLeft(integer+fraction, "0")
	if digits == "" {
		return 0, true
	}

	scale := new(big.Int).Sub(exponent, big.NewInt(int64(len(fraction))))
	if scale.Sign() < 0 {
		places := new(big.Int).Neg(scale)
		if !places.IsInt64() || places.Int64() > int64(len(digits)) {
			return 0, false
		}
		count := int(places.Int64())
		if count > 0 && strings.Trim(digits[len(digits)-count:], "0") != "" {
			return 0, false
		}
		digits = digits[:len(digits)-count]
	} else if scale.Sign() > 0 {
		// Any non-zero coefficient with more than 19 decimal digits cannot fit
		// int64. Check that bound before expanding an attacker-sized exponent.
		if !scale.IsInt64() || scale.Int64() > int64(19-len(digits)) {
			return 0, false
		}
		digits += strings.Repeat("0", int(scale.Int64()))
	}

	value, ok := new(big.Int).SetString(sign+digits, 10)
	if !ok || !value.IsInt64() {
		return 0, false
	}
	return value.Int64(), true
}

func toAnyArray(v any) ([]any, error) {
	switch a := v.(type) {
	case []any:
		return a, nil
	case []string:
		out := make([]any, len(a))
		for i, s := range a {
			out[i] = s
		}
		return out, nil
	case []int:
		out := make([]any, len(a))
		for i, n := range a {
			out[i] = int64(n)
		}
		return out, nil
	case []int64:
		out := make([]any, len(a))
		for i, n := range a {
			out[i] = n
		}
		return out, nil
	}
	return nil, fmt.Errorf("not an array: %T", v)
}
