// Package redact implements output redaction. Redactions are applied to
// stdout/stderr (and runbook final templates) before the data is returned to
// the caller or written to the local journal.
package redact

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const (
	privateKeyBlockPattern    = `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`
	pgpPrivateKeyBlockPattern = `-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*?-----END PGP PRIVATE KEY BLOCK-----`
)

// Rule is a compiled redaction directive.
type Rule struct {
	Name        string
	Replacement string

	regex   *regexp.Regexp
	literal string
}

// CompileRule turns a YAML redaction rule into a runtime Rule.
func CompileRule(r actionspec.RedactionRule) (Rule, error) {
	if r.Name == "" {
		return Rule{}, fmt.Errorf("redaction rule: missing name")
	}
	switch r.Type {
	case "regex":
		if r.Pattern == "" {
			return Rule{}, fmt.Errorf("redaction rule %s: missing pattern", r.Name)
		}
		re, err := regexp.Compile(r.Pattern)
		if err != nil {
			return Rule{}, fmt.Errorf("redaction rule %s: invalid regex: %w", r.Name, err)
		}
		repl := r.Replacement
		if repl == "" {
			repl = "[REDACTED]"
		}
		return Rule{Name: r.Name, Replacement: repl, regex: re}, nil
	case "literal":
		if r.Literal == "" {
			return Rule{}, fmt.Errorf("redaction rule %s: missing literal", r.Name)
		}
		repl := r.Replacement
		if repl == "" {
			repl = "[REDACTED]"
		}
		return Rule{Name: r.Name, Replacement: repl, literal: r.Literal}, nil
	}
	return Rule{}, fmt.Errorf("redaction rule %s: invalid type %q", r.Name, r.Type)
}

// DefaultRules returns redactions that are always applied as a last-resort
// safety net. They are conservative regexes for common secrets so that even
// an action that forgets to declare redactions cannot easily leak them.
func DefaultRules() []actionspec.RedactionRule {
	const secretName = `(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|private[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|session[_-]?token|account[_-]?key|aws[_-]?secret[_-]?access[_-]?key|aws[_-]?session[_-]?token)`
	const secretField = `(?:[A-Za-z0-9]+[._-])*` + secretName + `(?:[._-][A-Za-z0-9]+)*`

	return []actionspec.RedactionRule{
		{
			Name:        "bearer-token",
			Type:        "regex",
			Pattern:     `(?i)\bbearer\s+[A-Za-z0-9._~+\-/=]{8,}`,
			Replacement: "Bearer [REDACTED]",
		},
		{
			Name:        "basic-auth",
			Type:        "regex",
			Pattern:     `(?i)\bbasic\s+[A-Za-z0-9+/=]{8,}`,
			Replacement: "Basic [REDACTED]",
		},
		{
			Name:        "jwt",
			Type:        "regex",
			Pattern:     `\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b`,
			Replacement: "[REDACTED_JWT]",
		},
		{
			Name: "emisar-token",
			Type: "regex",
			// emisar credential prefixes (each followed by a base64url
			// random tail):
			//   emk-          — operator API keys (MCP / programmatic)
			//   rnrtok-       — per-runner tokens minted at registration
			//   emkey-enroll- — runner enrollment keys
			//   emo- / emor- / emoc- — OAuth access / refresh token and
			//                          authorization code
			// emkey-auth- (the enrollment keys' pre-rename prefix) and
			// tskey-auth- (pre-rebrand) are kept as legacy matches so keys
			// surfaced in old logs and host files still get redacted.
			Pattern:     `\b(?:(?:emk|rnrtok)-[A-Za-z0-9_-]{30,}|emo[rc]?-[A-Za-z0-9_-]{30,}|emkey-enroll-[A-Za-z0-9_-]{30,}|(?:emkey|tskey)-auth-[A-Za-z0-9_-]{30,})\b`,
			Replacement: "[REDACTED_EMISAR_TOKEN]",
		},
		{
			Name:        "aws-access-key",
			Type:        "regex",
			Pattern:     `\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`,
			Replacement: "[REDACTED_AWS_KEY]",
		},
		{
			Name:        "github-token",
			Type:        "regex",
			Pattern:     `\b(?:(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})\b`,
			Replacement: "[REDACTED_GH_TOKEN]",
		},
		{
			Name:        "gitlab-token",
			Type:        "regex",
			Pattern:     `\bglpat-[A-Za-z0-9_-]{20,}\b`,
			Replacement: "[REDACTED_GITLAB_TOKEN]",
		},
		{
			Name:        "slack-token",
			Type:        "regex",
			Pattern:     `\bxox[baprs]-[A-Za-z0-9-]{10,}\b`,
			Replacement: "[REDACTED_SLACK_TOKEN]",
		},
		{
			Name:        "stripe-secret-key",
			Type:        "regex",
			Pattern:     `\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b`,
			Replacement: "[REDACTED_STRIPE_KEY]",
		},
		{
			Name:        "openai-api-key",
			Type:        "regex",
			Pattern:     `\b(?:sk-(?:proj|svcacct)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,})\b`,
			Replacement: "[REDACTED_OPENAI_KEY]",
		},
		{
			Name:        "anthropic-api-key",
			Type:        "regex",
			Pattern:     `\bsk-ant-api[0-9]{2}-[A-Za-z0-9_-]{20,}\b`,
			Replacement: "[REDACTED_ANTHROPIC_KEY]",
		},
		{
			Name:        "google-api-key",
			Type:        "regex",
			Pattern:     `\bAIza[0-9A-Za-z_-]{35}\b`,
			Replacement: "[REDACTED_GOOGLE_API_KEY]",
		},
		{
			Name:        "npm-token",
			Type:        "regex",
			Pattern:     `\bnpm_[A-Za-z0-9]{36}\b`,
			Replacement: "[REDACTED_NPM_TOKEN]",
		},
		{
			Name:        "sendgrid-api-key",
			Type:        "regex",
			Pattern:     `\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b`,
			Replacement: "[REDACTED_SENDGRID_KEY]",
		},
		{
			Name:        "private-key-block",
			Type:        "regex",
			Pattern:     privateKeyBlockPattern,
			Replacement: "[REDACTED_PRIVATE_KEY]",
		},
		{
			Name:        "pgp-private-key-block",
			Type:        "regex",
			Pattern:     pgpPrivateKeyBlockPattern,
			Replacement: "[REDACTED_PRIVATE_KEY]",
		},
		{
			Name:        "url-credentials",
			Type:        "regex",
			Pattern:     `(?i)\b([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@`,
			Replacement: "${1}[REDACTED]@",
		},
		{
			Name:        "cookie-header",
			Type:        "regex",
			Pattern:     `(?i)\b(set-cookie|cookie):\s*[^\r\n]+`,
			Replacement: "${1}: [REDACTED]",
		},
		{
			Name:        "json-secret-field",
			Type:        "regex",
			Pattern:     `(?i)("` + secretField + `"\s*:\s*)"[^"\r\n]*"`,
			Replacement: `${1}"[REDACTED]"`,
		},
		{
			Name:        "secret-assignment",
			Type:        "regex",
			Pattern:     `(?i)\b(` + secretField + `\s*[:=]\s*)("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]\[]+)`,
			Replacement: "${1}[REDACTED]",
		},
	}
}

// CompileAll compiles rules + DefaultRules. It returns the combined list.
// Duplicates by Name are dropped, preferring the first occurrence.
func CompileAll(rules ...[]actionspec.RedactionRule) ([]Rule, error) {
	out := make([]Rule, 0)
	seen := make(map[string]struct{})
	all := []actionspec.RedactionRule{}
	for _, batch := range rules {
		all = append(all, batch...)
	}
	for _, r := range all {
		if _, ok := seen[r.Name]; ok {
			continue
		}
		c, err := CompileRule(r)
		if err != nil {
			return nil, err
		}
		seen[r.Name] = struct{}{}
		out = append(out, c)
	}
	return out, nil
}

// apply runs a single Rule on s, returning the new string and the number of
// substitutions performed.
func (r Rule) apply(s string) (string, int) {
	if r.regex != nil {
		count := len(r.regex.FindAllStringIndex(s, -1))
		if count == 0 {
			return s, 0
		}
		return r.regex.ReplaceAllString(s, r.Replacement), count
	}
	if r.literal != "" {
		count := strings.Count(s, r.literal)
		if count == 0 {
			return s, 0
		}
		return strings.ReplaceAll(s, r.literal, r.Replacement), count
	}
	return s, 0
}
