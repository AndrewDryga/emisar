package validation

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const defaultMaxStringBytes = 32 << 10

// Validate normalizes raw against the arg schema. It returns a new map of
// validated values (only declared args) or a *Error describing the first
// failure. raw must not be mutated.
// A float64 round-trips in at most 24 characters; 64 leaves room for an
// author's padded literal without leaving the door open to a 30 KB one.
const maxNumberLiteralBytes = 64

// The backstop element count for an array arg whose pack declares no max_items.
// Generous next to the largest any shipped pack asks for (32), and far below
// what the envelope alone allowed.
const defaultMaxItems = 256

// protected lists absolute roots no action argument may name, whatever the
// pack declares. Callers outside the dispatch path (the authoring-time lints)
// pass nil: they validate example values against a schema, not a real host.
func Validate(schema []actionspec.Arg, raw map[string]any, protected []string) (map[string]any, error) {
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
		validated, err := applyValidation(a, coerced)
		if err != nil {
			return nil, err
		}
		if err := refuseProtectedPaths(a, validated, protected); err != nil {
			return nil, err
		}
		out[a.Name] = validated
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
			// A json.Number is kept VERBATIM so a value round-trips exactly, and
			// that literal is what renders into program text. min/max say nothing
			// about its length: "1." plus 30,000 zeros plus "1" satisfies
			// min:0,max:10 and arrives as 30 KB of digits. A two-sided bounded
			// number is one of the few things a pack may render into a command,
			// so its LENGTH has to be bounded too.
			if len(number) > maxNumberLiteralBytes {
				return nil, newError(a.Name, "type",
					"number literal is too long (%d bytes, max %d)", len(number), maxNumberLiteralBytes)
			}
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

func applyValidation(a actionspec.Arg, v any) (any, error) {
	if err := applyStringByteLimit(a, v); err != nil {
		return nil, err
	}
	// Ahead of the nil-Validation return, because an arg with no `validation:`
	// block is exactly the one that had no element bound at all.
	if err := applyArrayItemLimit(a, v); err != nil {
		return nil, err
	}
	if a.Validation == nil {
		return v, nil
	}
	val := a.Validation

	// Arrays apply max_items at array scope, scalar validators per-element.
	if isArrayType(a.Type) {
		elements, err := elementsOf(v)
		if err != nil {
			return nil, newError(a.Name, "type", "%s", err.Error())
		}
		for i, elem := range elements {
			if err := applyScalarValidators(a, val, elem); err != nil {
				return nil, wrapElementError(err, i)
			}
		}
		return applyPathValidation(a, val, v)
	}

	if err := applyScalarValidators(a, val, v); err != nil {
		return nil, err
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
	// Arg.Validate settles the schema shapes this section would otherwise have
	// to re-check: pattern only on string/path args and compiled at pack load,
	// min/max only on numeric args, min_duration/max_duration only on duration
	// args. Coerce then produces the matching Go type, so each validator reads
	// its value directly.
	if val.Pattern != "" {
		s, _ := v.(string)
		if !matchesPattern(val.Pattern, s) {
			return newError(a.Name, "pattern", "must match pattern %s", val.Pattern)
		}
	}
	if val.Min != nil && belowNumericBound(v, *val.Min) {
		return newError(a.Name, "min", "must be >= %v", *val.Min)
	}
	if val.Max != nil && aboveNumericBound(v, *val.Max) {
		return newError(a.Name, "max", "must be <= %v", *val.Max)
	}
	if val.MinDuration != nil || val.MaxDuration != nil {
		d, _ := v.(time.Duration)
		if val.MinDuration != nil && d < val.MinDuration.Std() {
			return newError(a.Name, "min_duration", "must be >= %s", val.MinDuration.Std())
		}
		if val.MaxDuration != nil && d > val.MaxDuration.Std() {
			return newError(a.Name, "max_duration", "must be <= %s", val.MaxDuration.Std())
		}
	}
	return nil
}

// patterns holds every arg pattern this process has compiled. The set comes
// from the installed packs, so it is small and fixed once they are loaded —
// without it every dispatch recompiled the same regex.
var patterns sync.Map // pattern -> *regexp.Regexp

func matchesPattern(pattern, s string) bool {
	cached, ok := patterns.Load(pattern)
	if !ok {
		compiled, err := regexp.Compile(pattern)
		if err != nil {
			// Arg.Validate compiled this at pack load, so it cannot fail for a
			// loaded action; refuse the value rather than admit it unchecked.
			return false
		}
		patterns.Store(pattern, compiled)
		cached = compiled
	}
	return cached.(*regexp.Regexp).MatchString(s)
}

// An integer arg compares in int64: Arg.Validate pins its bounds to exactly
// represented integers, so a job id past 2^53 keeps its true order against one.
// A number arg compares as the float64 its literal denotes.
func belowNumericBound(value any, bound float64) bool {
	if n, ok := value.(int64); ok {
		return n < int64(bound)
	}
	f, ok := toFloat(value)
	return ok && f < bound
}

func aboveNumericBound(value any, bound float64) bool {
	if n, ok := value.(int64); ok {
		return n > int64(bound)
	}
	f, ok := toFloat(value)
	return ok && f > bound
}

// applyPathValidation runs path allow/deny rules and returns the canonical
// target(s) that passed them. It accepts string and []string via stringsFor.
func applyPathValidation(a actionspec.Arg, val *actionspec.Validation, v any) (any, error) {
	if len(val.AllowedPaths) == 0 && len(val.DeniedPaths) == 0 &&
		len(val.AllowedPrefixes) == 0 && len(val.DeniedPrefixes) == 0 {
		return v, nil
	}
	strs, err := stringsFor(a, v)
	if err != nil {
		return nil, err
	}
	// Resolve allow/deny lists too so an author writing /var/log on a
	// host where /var → /private/var still gets a matching comparison
	// against an input that resolves to /private/var/log/...
	allowedPaths, err := resolveManyRules(val.AllowedPaths)
	if err != nil {
		return nil, newError(a.Name, "path", "cannot safely resolve allowed_paths: %v", err)
	}
	deniedPaths, err := resolveManyRules(val.DeniedPaths)
	if err != nil {
		return nil, newError(a.Name, "path", "cannot safely resolve denied_paths: %v", err)
	}
	allowedPrefixes, err := resolveManyRules(val.AllowedPrefixes)
	if err != nil {
		return nil, newError(a.Name, "path", "cannot safely resolve allowed_prefixes: %v", err)
	}
	deniedPrefixes, err := resolveManyRules(val.DeniedPrefixes)
	if err != nil {
		return nil, newError(a.Name, "path", "cannot safely resolve denied_prefixes: %v", err)
	}
	lexicalDeniedPaths := cleanMany(val.DeniedPaths)
	lexicalDeniedPrefixes := cleanMany(val.DeniedPrefixes)

	resolvedValues := make([]string, 0, len(strs))
	for _, s := range strs {
		cleaned := filepath.Clean(s)
		// Reject lexical deny matches before resolving the request. Protected
		// trees such as /root/.ssh are deliberately unreadable to a non-root
		// runner, but a direct or dot-dot path into them is still an exact deny.
		if pathInDenyList(cleaned, lexicalDeniedPaths) {
			return nil, newError(a.Name, "denied_paths", "path %s is denied", cleaned)
		}
		if prefixInDenyList(cleaned, lexicalDeniedPrefixes) {
			return nil, newError(a.Name, "denied_prefixes", "path %s under denied prefix", cleaned)
		}
		resolved, err := resolveForCheck(s)
		if err != nil {
			return nil, newError(a.Name, "path", "cannot safely resolve path %s: %v", s, err)
		}
		// A relative value never matches an absolute allow/deny list, so it
		// would slip past the deny checks below and then be run by the
		// executor under its CWD — resolving to a denied absolute path. Path
		// rules only make sense against the absolute path the executor uses,
		// so require one.
		if !filepath.IsAbs(resolved) {
			return nil, newError(a.Name, "path", "path %s must be absolute", resolved)
		}
		if len(allowedPaths) > 0 && !pathInList(resolved, allowedPaths) {
			return nil, newError(a.Name, "allowed_paths", "path %s not in allowlist", resolved)
		}
		if pathInDenyList(resolved, deniedPaths) {
			return nil, newError(a.Name, "denied_paths", "path %s is denied", resolved)
		}
		if len(allowedPrefixes) > 0 && !prefixInList(resolved, allowedPrefixes) {
			return nil, newError(a.Name, "allowed_prefixes", "path %s not in allowed prefixes", resolved)
		}
		if prefixInDenyList(resolved, deniedPrefixes) {
			return nil, newError(a.Name, "denied_prefixes", "path %s under denied prefix", resolved)
		}
		resolvedValues = append(resolvedValues, resolved)
	}
	if _, ok := v.([]string); ok {
		return resolvedValues, nil
	}
	return resolvedValues[0], nil
}

// refuseProtectedPaths keeps an action argument from naming the runner's own
// state, whatever its pack declared. A pack's denied_prefixes cannot do this
// job: the operator picks these directories at install time (--etc-dir,
// --data-dir), long after the catalog was authored, and every path arg in
// every pack would have to repeat them. The runner knows where they are, so
// the runner refuses them.
//
// The stakes are the whole runner identity, not one file: the config dir holds
// runner.env — the enrollment key plus every pack credential the operator
// exported (NOMAD_TOKEN, PGPASSWORD, ...) — and the data dir holds the bearer
// token that authenticates this runner to the control plane. Reading either
// impersonates the runner, so it must not depend on a pack getting its
// denylist right.
//
// Every string-shaped value is checked, whatever type the pack gave it. Keying
// this on `type: path` (or on a declared path rule) meant an author who wrote
// `type: string` with only an anchored pattern — the mistake packs/AGENTS.md
// already warns about for containment — silently lost the runner-identity
// refusal as well. A value that is not an absolute path costs one Clean here
// and resolves no further.
func refuseProtectedPaths(a actionspec.Arg, v any, protected []string) error {
	if len(protected) == 0 {
		return nil
	}
	var values []string
	switch typed := v.(type) {
	case string:
		values = []string{typed}
	case []string:
		values = typed
	default:
		return nil
	}
	// Resolve the roots the same way declared rules are resolved, so a host
	// where /var is a symlink still compares like with like.
	resolved, err := resolveManyRules(protected)
	if err != nil {
		return newError(a.Name, "path", "cannot safely resolve protected paths: %v", err)
	}
	lexical := cleanMany(protected)
	for _, s := range values {
		// Lexically first: the store is normally unreadable to the service
		// user, but a direct or dot-dot path into it is still an exact refusal.
		if prefixInDenyList(filepath.Clean(s), lexical) {
			return protectedPathError(a, s)
		}
		// An identifier that merely looks like a path (a log group, a znode)
		// never reaches an existing component, so tolerating an unreadable one
		// keeps those args working; the refusal below is a denial check, and
		// applyPathValidation still resolves a real path arg strictly.
		target, err := resolveRuleForCheck(s)
		if err != nil {
			return newError(a.Name, "path", "cannot safely resolve path %s: %v", s, err)
		}
		if prefixInDenyList(target, resolved) {
			return protectedPathError(a, target)
		}
	}
	return nil
}

func protectedPathError(a actionspec.Arg, path string) error {
	return newError(a.Name, "protected_path",
		"path %s is inside the runner's own configuration or state", path)
}

func cleanMany(in []string) []string {
	out := make([]string, len(in))
	for i, p := range in {
		out[i] = filepath.Clean(p)
	}
	return out
}

func resolveManyRules(in []string) ([]string, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(in))
	for _, p := range in {
		resolved, err := resolveRuleForCheck(p)
		if err != nil {
			return nil, fmt.Errorf("%q: %w", p, err)
		}
		out = append(out, resolved)
	}
	return out, nil
}

// resolveForCheck cleans p and resolves symlinks, even when the leaf doesn't
// exist yet. It walks up to the deepest existing parent, EvalSymlinks-resolves
// it, and re-attaches the missing tail. This blocks the attack where
// /var/log/<symlink>/foo points to /etc/foo before /etc/foo exists: the
// symlinked parent resolves to /etc, and the resulting /etc/foo fails any
// allowed_prefixes check pinned to /var/log/.
func resolveForCheck(p string) (string, error) {
	return resolvePathForCheck(p, false)
}

// resolveRuleForCheck is the same walk for a path that may legitimately sit
// somewhere this process cannot read: a declared allow/deny rule, or a value
// refuseProtectedPaths is only comparing against the runner's own roots. It
// canonicalizes every inspectable ancestor and lets an unreadable tail stay
// lexical, so one unreadable rule cannot poison every otherwise-benign action
// on a non-root runner. Neither caller grants execution — applyPathValidation
// resolves the value it returns with resolveForCheck, which still rejects an
// unreadable component — so this cannot turn an uninspectable input into an
// executable path.
func resolveRuleForCheck(p string) (string, error) {
	return resolvePathForCheck(p, true)
}

// resolvePathForCheck is the containment walk both callers share. It was two
// copies that differed in exactly one token — whether a permission error on an
// ancestor is tolerated — which is the last place this module should carry a
// second definition: a hardening applied to one copy would silently skip the
// other.
func resolvePathForCheck(p string, tolerateUnreadable bool) (string, error) {
	cleaned := filepath.Clean(p)
	if !filepath.IsAbs(cleaned) {
		return cleaned, nil
	}
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return resolved, nil
	}
	// Walk up until we find an existing parent. We may walk all the way to the
	// volume root ("/"); that's fine — its EvalSymlinks is "/".
	tail := ""
	parent := cleaned
	for {
		_, err := os.Lstat(parent)
		switch {
		case err == nil:
			resolved, err := filepath.EvalSymlinks(parent)
			if err != nil {
				return "", fmt.Errorf("resolve existing component %q: %w", parent, err)
			}
			return filepath.Clean(filepath.Join(resolved, tail)), nil
		case os.IsNotExist(err):
			// Keep walking up; the leaf simply does not exist yet.
		case tolerateUnreadable && os.IsPermission(err):
			// Keep walking up; a rule may sit behind a directory we cannot read.
		default:
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
	case json.Number, float64:
		// A number arg's membership is decided on the value its literal denotes,
		// not on the spelling: 1.250 and 1.25 are the same number.
		af, aok := toFloat(av)
		bf, bok := toFloat(b)
		return aok && bok && af == bf
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

// pathInDenyList and prefixInDenyList fold case. EvalSymlinks resolves links
// but never normalizes case, so on a case-insensitive filesystem — APFS by
// default on macOS, a published runner platform, and ext4 casefold / CIFS /
// vfat subtrees on Linux — /etc/EMISAR/runner.env opens the same file as
// /etc/emisar/runner.env and an exact compare waves it straight past a
// deny-only pack rule and past the runner's own protected roots. Refusing a
// case variant on a case-sensitive host is the fail-closed error and no
// shipped rule distinguishes two paths by case alone. The ALLOW direction
// keeps the exact compare: there the same fold would widen access instead, and
// a case variant that misses an allowlist is already refused.
func pathInDenyList(path string, list []string) bool {
	for _, p := range list {
		if strings.EqualFold(filepath.Clean(p), path) {
			return true
		}
	}
	return false
}

func prefixInList(path string, prefixes []string) bool {
	for _, p := range prefixes {
		if underPrefix(path, filepath.Clean(p), false) {
			return true
		}
	}
	return false
}

func prefixInDenyList(path string, prefixes []string) bool {
	for _, p := range prefixes {
		if underPrefix(path, filepath.Clean(p), true) {
			return true
		}
	}
	return false
}

func underPrefix(path, prefix string, fold bool) bool {
	// Root covers every absolute path; prefix+separator would be "//",
	// which never prefixes a cleaned path, so special-case it.
	if prefix == string(filepath.Separator) {
		return true
	}
	if len(path) < len(prefix) {
		return false
	}
	if len(path) > len(prefix) && path[len(prefix)] != filepath.Separator {
		return false
	}
	head := path[:len(prefix)]
	if fold {
		return strings.EqualFold(head, prefix)
	}
	return head == prefix
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
		// An integer arg takes the plain integer spelling only: ParseInt refuses
		// a fraction or an exponent, so "1e3" and "1000.0" are a type error the
		// caller fixes by sending 1000. The alternative was evaluating every
		// spelling exactly, which bought nothing an operator reading the
		// approval — or the argv the script receives — would recognize.
		if i, err := strconv.ParseInt(n.String(), 10, 64); err == nil {
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

// applyArrayItemLimit enforces the author's max_items when they set one and a
// backstop when they do not. Every array element becomes its own argv token, so
// an array with no declared ceiling was bounded only by the 32 KiB envelope —
// roughly 10,000 tokens. The largest max_items any shipped pack asks for is 32.
func applyArrayItemLimit(a actionspec.Arg, v any) error {
	if !isArrayType(a.Type) {
		return nil
	}
	limit := defaultMaxItems
	if a.Validation != nil && a.Validation.MaxItems != nil {
		limit = *a.Validation.MaxItems
	}
	if n, _ := arrayLen(v); n > limit {
		return newError(a.Name, "max_items", "too many items (max %d)", limit)
	}
	return nil
}
