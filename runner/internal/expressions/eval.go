// Package expressions implements a tiny template engine used to render
// action argv and environment variables. It only supports variable
// substitution of validated action arguments:
//
//	"{{ args.host }}"
//	"--port={{ args.port }}"
//	"{{ args.paths }}"          // expands in argv if it resolves to an array
//
// There are no functions, no comparisons, no arithmetic. Runbook logic
// (asserts, when conditions, multi-step orchestration) lives in the cloud
// control plane; the runner never evaluates it.
package expressions

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Render substitutes every "{{ args.x }}" block in tmpl with the formatted
// value from args. The result is always a string.
//
// Whole-template expressions that resolve to arrays are an error here; use
// RenderArgv if you want array expansion.
func Render(tmpl string, args map[string]any) (string, error) {
	var b strings.Builder
	i := 0
	for i < len(tmpl) {
		j := strings.Index(tmpl[i:], "{{")
		if j < 0 {
			b.WriteString(tmpl[i:])
			break
		}
		b.WriteString(tmpl[i : i+j])
		i += j + 2
		end := strings.Index(tmpl[i:], "}}")
		if end < 0 {
			return "", fmt.Errorf("unterminated template at offset %d", i-2)
		}
		expr := strings.TrimSpace(tmpl[i : i+end])
		i += end + 2
		v, err := resolve(expr, args)
		if err != nil {
			return "", fmt.Errorf("template %q: %w", expr, err)
		}
		s, err := formatScalar(v)
		if err != nil {
			return "", fmt.Errorf("template %q: %w", expr, err)
		}
		b.WriteString(s)
	}
	return b.String(), nil
}

// RenderArgv renders each element of argv. An element that is exactly a
// single "{{ args.x }}" with no surrounding text and that resolves to an
// array is expanded into multiple argv elements. All other elements are
// rendered as scalar strings.
//
// Option-injection note: a whole-expression element like "{{ args.target }}"
// becomes its own argv token, so a value beginning with "-" reaches the target
// binary as a flag, not a positional (argv arrays prevent SHELL injection, not
// the target's own option parsing — e.g. a curl URL of "-o/etc/x"). The runner
// can't reject leading dashes globally (negative numbers and intentional flags
// are legitimate), so the mitigation is per action at authoring time: place a
// literal "--" end-of-options marker before user-controlled positionals
// (["curl", "--", "{{ args.url }}"]) and/or constrain the arg with a
// validation.pattern. Keep this in mind when reviewing exec-kind packs.
func RenderArgv(argv []string, args map[string]any) ([]string, error) {
	out := make([]string, 0, len(argv))
	for _, raw := range argv {
		expr, ok := wholeExpression(raw)
		if ok {
			v, err := resolve(expr, args)
			if err != nil {
				return nil, fmt.Errorf("argv %q: %w", raw, err)
			}
			expanded, did, err := expandArray(v)
			if err != nil {
				return nil, fmt.Errorf("argv %q: %w", raw, err)
			}
			if did {
				out = append(out, expanded...)
				continue
			}
			s, err := formatScalar(v)
			if err != nil {
				return nil, fmt.Errorf("argv %q: %w", raw, err)
			}
			out = append(out, s)
			continue
		}
		s, err := Render(raw, args)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

// RenderEnv renders every value in env. Keys are not templated.
func RenderEnv(env map[string]string, args map[string]any) (map[string]string, error) {
	if len(env) == 0 {
		return nil, nil
	}
	out := make(map[string]string, len(env))
	for k, v := range env {
		rendered, err := Render(v, args)
		if err != nil {
			return nil, fmt.Errorf("env %s: %w", k, err)
		}
		out[k] = rendered
	}
	return out, nil
}

// resolve evaluates a single "args.<name>" expression. Unknown variables and
// any other syntax (function calls, operators, etc.) are errors.
func resolve(expr string, args map[string]any) (any, error) {
	const prefix = "args."
	if !strings.HasPrefix(expr, prefix) {
		return nil, fmt.Errorf("unknown variable %q (only args.* is supported)", expr)
	}
	name := expr[len(prefix):]
	if name == "" || !validIdent(name) {
		return nil, fmt.Errorf("invalid args reference %q", expr)
	}
	v, ok := args[name]
	if !ok {
		return nil, fmt.Errorf("unknown variable args.%s", name)
	}
	return v, nil
}

func validIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, c := range s {
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c == '_':
		case c >= '0' && c <= '9':
			if i == 0 {
				return false
			}
		default:
			return false
		}
	}
	return true
}

// wholeExpression returns the expression body if s is exactly "{{ ... }}".
func wholeExpression(s string) (string, bool) {
	t := strings.TrimSpace(s)
	if !strings.HasPrefix(t, "{{") || !strings.HasSuffix(t, "}}") {
		return "", false
	}
	body := strings.TrimSpace(t[2 : len(t)-2])
	if strings.Contains(body, "{{") || strings.Contains(body, "}}") {
		return "", false
	}
	return body, true
}

// ArgStrings returns the argv token string form(s) of a resolved arg value,
// mirroring RenderArgv's expansion: each element for an array-typed value, or
// the single scalar form otherwise. Callers that mask secrets out of the
// rendered command (engine redaction) use it so they match the exact tokens
// that reach argv — a list secret expands into separate tokens, not one
// bracketed "%v" blob. Values it cannot format yield no strings.
func ArgStrings(v any) []string {
	if elems, ok, err := expandArray(v); ok {
		if err != nil {
			return nil
		}
		return elems
	}
	if s, err := formatScalar(v); err == nil {
		return []string{s}
	}
	return nil
}

func expandArray(v any) ([]string, bool, error) {
	switch arr := v.(type) {
	case []string:
		return append([]string(nil), arr...), true, nil
	case []any:
		out := make([]string, 0, len(arr))
		for i, item := range arr {
			s, err := formatScalar(item)
			if err != nil {
				return nil, false, fmt.Errorf("element %d: %w", i, err)
			}
			out = append(out, s)
		}
		return out, true, nil
	case []int64:
		out := make([]string, 0, len(arr))
		for _, n := range arr {
			out = append(out, strconv.FormatInt(n, 10))
		}
		return out, true, nil
	}
	return nil, false, nil
}

func formatScalar(v any) (string, error) {
	switch t := v.(type) {
	case nil:
		return "", nil
	case string:
		return t, nil
	case bool:
		if t {
			return "true", nil
		}
		return "false", nil
	case int:
		return strconv.FormatInt(int64(t), 10), nil
	case int64:
		return strconv.FormatInt(t, 10), nil
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64), nil
	case time.Duration:
		// Render as Go-style duration ("5m", "1h30m") so downstream
		// binaries that accept either Go-style or "5 minutes" can parse
		// it. Pack authors who need a different format can do their own
		// substitution upstream.
		return t.String(), nil
	}
	return "", fmt.Errorf("cannot format value of type %T as string", v)
}
