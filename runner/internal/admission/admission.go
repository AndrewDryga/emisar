// Package admission is the runner-local action allowlist / denylist.
//
// The control plane decides what *should* run; admission decides what the
// host operator will *permit* to run, regardless of what the cloud says.
// This is defense-in-depth: even a compromised portal cannot push an
// action whose id doesn't match the local policy.
//
// Admission has two axes — action id (allow/deny globs) and risk ceiling.
// Both hide a rejected action from the advertised catalog AND refuse it at
// dispatch, so neither a stale nor a compromised portal can run what the
// operator suppressed.
//
// Policy rules:
//
//   - Empty allow + empty deny → everything passes (default behavior).
//   - Non-empty allow → action id MUST match at least one allow pattern.
//   - Non-empty deny → action id MUST NOT match any deny pattern.
//   - When both are set, allow is evaluated first, then deny.
//   - A risk ceiling (max_risk) rejects any action above that tier — the
//     one-flag "read-only demo" switch (see AdmitRisk).
//
// Patterns use shell-style globs interpreted by `filepath.Match`. Action
// ids look like `pack.action_name`; since the dot is not a path
// separator on any supported OS, `cassandra.*` matches every action in
// the cassandra pack. `*` matches the whole id, `*.restart` matches any
// pack's `restart` action.
package admission

import (
	"fmt"
	"path/filepath"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// Policy is the compiled, read-only admission decision tree. Construct
// once at runner boot via New and treat as immutable thereafter.
type Policy struct {
	allow   []string
	deny    []string
	maxRisk actionspec.Risk
}

// New compiles a policy. Each pattern is validated by trial-matching
// against a sentinel; an invalid pattern (e.g. an unterminated `[`) is
// rejected here so the runner refuses to boot rather than silently
// admitting everything. maxRisk is an optional risk ceiling ("" = none),
// validated by config before it reaches here.
func New(allow, deny []string, maxRisk actionspec.Risk) (*Policy, error) {
	if err := validatePatterns("admission.allow", allow); err != nil {
		return nil, err
	}
	if err := validatePatterns("admission.deny", deny); err != nil {
		return nil, err
	}
	return &Policy{
		allow:   append([]string(nil), allow...),
		deny:    append([]string(nil), deny...),
		maxRisk: maxRisk,
	}, nil
}

// Admit reports whether actionID is permitted by the policy.
//
// Returns (true, "") on admission, (false, reason) on rejection. The
// reason is operator-readable and is intended for both the JSONL audit
// log and the cloud-bound Result payload — keep it short and concrete.
func (p *Policy) Admit(actionID string) (bool, string) {
	if p == nil {
		return true, ""
	}

	if len(p.allow) > 0 {
		if !matchAny(p.allow, actionID) {
			return false, fmt.Sprintf("action %q not on runner allowlist", actionID)
		}
	}

	if len(p.deny) > 0 {
		if matched := firstMatch(p.deny, actionID); matched != "" {
			return false, fmt.Sprintf("action %q blocked by runner denylist (pattern %q)", actionID, matched)
		}
	}

	return true, ""
}

// AdmitRisk reports whether an action of the given risk is permitted by the
// policy's risk ceiling. With no ceiling set, everything passes. An action
// whose risk exceeds the ceiling (or carries an invalid risk — fail closed)
// is rejected with an operator-readable reason, the same as Admit.
func (p *Policy) AdmitRisk(risk actionspec.Risk) (bool, string) {
	if p == nil || p.maxRisk == "" {
		return true, ""
	}
	if !risk.LessOrEqual(p.maxRisk) {
		return false, fmt.Sprintf("action risk %q exceeds runner ceiling %q", risk, p.maxRisk)
	}
	return true, ""
}

func matchAny(patterns []string, id string) bool {
	for _, p := range patterns {
		// filepath.Match only returns an error for malformed patterns,
		// which we already rejected in New. Treat a runtime error here
		// as "no match" defensively — admission must fail closed.
		ok, err := filepath.Match(p, id)
		if err == nil && ok {
			return true
		}
	}
	return false
}

func firstMatch(patterns []string, id string) string {
	for _, p := range patterns {
		ok, err := filepath.Match(p, id)
		if err == nil && ok {
			return p
		}
	}
	return ""
}

func validatePatterns(field string, patterns []string) error {
	for i, p := range patterns {
		if p == "" {
			return fmt.Errorf("%s[%d]: empty pattern", field, i)
		}
		// `filepath.Match` only checks the pattern when it has something
		// to match against; trial-match against a placeholder so a
		// malformed pattern surfaces at boot, not at first request.
		if _, err := filepath.Match(p, "probe"); err != nil {
			return fmt.Errorf("%s[%d] %q: %w", field, i, p, err)
		}
	}
	return nil
}
