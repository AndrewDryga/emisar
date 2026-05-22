package redact

// Engine applies a fixed set of compiled redaction rules.
type Engine struct {
	rules []Rule
}

// New returns an Engine that will apply rules in order.
func New(rules []Rule) *Engine {
	return &Engine{rules: rules}
}

// Empty returns an Engine that performs no redaction.
func Empty() *Engine { return &Engine{} }

// Extend returns a new Engine that applies extra first (action-local rules),
// then e's rules (global rules). The receiver is unchanged.
func (e *Engine) Extend(extra []Rule) *Engine {
	if e == nil || len(e.rules) == 0 {
		return New(extra)
	}
	if len(extra) == 0 {
		return e
	}
	merged := make([]Rule, 0, len(extra)+len(e.rules))
	merged = append(merged, extra...)
	merged = append(merged, e.rules...)
	return New(merged)
}

// Hit is a per-rule redaction count.
type Hit struct {
	Name  string
	Type  string
	Count int
}

// Apply redacts s and reports per-rule hit counts. Rules are applied in
// declaration order; later rules see earlier rules' output.
func (e *Engine) Apply(s string) (string, []Hit) {
	if e == nil || len(e.rules) == 0 {
		return s, nil
	}
	var hits []Hit
	for _, r := range e.rules {
		out, n := r.apply(s)
		if n > 0 {
			t := "regex"
			if r.regex == nil {
				t = "literal"
			}
			hits = append(hits, Hit{Name: r.Name, Type: t, Count: n})
		}
		s = out
	}
	return s, hits
}

// MergeHits sums hit counts by rule name. Used when redaction runs over
// multiple streams (stdout/stderr) and we want a single per-action summary.
func MergeHits(hs ...[]Hit) []Hit {
	idx := make(map[string]*Hit)
	var order []string
	for _, batch := range hs {
		for _, h := range batch {
			if existing, ok := idx[h.Name]; ok {
				existing.Count += h.Count
				continue
			}
			copy := h
			idx[h.Name] = &copy
			order = append(order, h.Name)
		}
	}
	out := make([]Hit, 0, len(order))
	for _, name := range order {
		out = append(out, *idx[name])
	}
	return out
}
