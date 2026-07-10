package validation

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

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
	if val.MaxLength != nil {
		s, ok := v.(string)
		if !ok {
			return newError(a.Name, "max_length", "max_length requires string value")
		}
		if len(s) > *val.MaxLength {
			return newError(a.Name, "max_length", "must be at most %d bytes (got %d)", *val.MaxLength, len(s))
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
		f, ok := toFloat(v)
		if !ok {
			return newError(a.Name, "min", "min requires numeric value")
		}
		if f < *val.Min {
			return newError(a.Name, "min", "must be >= %v", *val.Min)
		}
	}
	if val.Max != nil {
		f, ok := toFloat(v)
		if !ok {
			return newError(a.Name, "max", "max requires numeric value")
		}
		if f > *val.Max {
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
	allowedPaths := resolveMany(val.AllowedPaths)
	deniedPaths := resolveMany(val.DeniedPaths)
	allowedPrefixes := resolveMany(val.AllowedPrefixes)
	deniedPrefixes := resolveMany(val.DeniedPrefixes)

	for _, s := range strs {
		resolved := resolveForCheck(s)
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

func resolveMany(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	out := make([]string, 0, len(in))
	for _, p := range in {
		out = append(out, resolveForCheck(p))
	}
	return out
}

// resolveForCheck cleans p and resolves symlinks, even when the leaf
// doesn't exist yet. It walks up to the deepest existing parent,
// EvalSymlinks-resolves it, and re-attaches the missing tail. This
// blocks the attack where /var/log/<symlink>/foo points to /etc/foo
// before /etc/foo exists: the symlinked parent resolves to /etc, and
// the resulting /etc/foo fails any allowed_prefixes check pinned to
// /var/log/.
func resolveForCheck(p string) string {
	cleaned := filepath.Clean(p)
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return resolved
	}
	// Walk up until we find an existing parent. We may walk all the way
	// to the volume root ("/"); that's fine — its EvalSymlinks is "/".
	tail := ""
	parent := cleaned
	for {
		if parent == "" || parent == "/" || parent == "." {
			// No deeper parent. Use cleaned path as-is.
			return cleaned
		}
		if _, err := os.Lstat(parent); err == nil {
			break
		}
		tail = filepath.Join(filepath.Base(parent), tail)
		parent = filepath.Dir(parent)
	}
	resolved, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return cleaned
	}
	return filepath.Clean(filepath.Join(resolved, tail))
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
	case float64:
		bn, ok := toFloat(b)
		return ok && av == bn
	case bool:
		bb, ok := b.(bool)
		return ok && av == bb
	}
	return a == b
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
		return int64(n), true
	case uint32:
		return int64(n), true
	case uint64:
		return int64(n), true
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
		return float64(n), true
	case float64:
		return n, true
	case string:
		f, err := strconv.ParseFloat(n, 64)
		if err == nil {
			return f, true
		}
	}
	return 0, false
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
