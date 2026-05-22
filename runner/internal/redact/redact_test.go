package redact

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestEngine_LiteralAndRegex(t *testing.T) {
	rules, err := CompileAll([]actionspec.RedactionRule{
		{Name: "lit", Type: "literal", Literal: "topsecret", Replacement: "X"},
		{Name: "re", Type: "regex", Pattern: "[0-9]+", Replacement: "N"},
	})
	if err != nil {
		t.Fatal(err)
	}
	e := New(rules)
	out, hits := e.Apply("hello topsecret 12345 topsecret end")
	if strings.Contains(out, "topsecret") {
		t.Fatalf("literal not redacted: %q", out)
	}
	if strings.Contains(out, "12345") {
		t.Fatalf("regex not redacted: %q", out)
	}
	if len(hits) != 2 {
		t.Fatalf("hits: got %+v", hits)
	}
}

func TestEngine_DefaultRulesBearerToken(t *testing.T) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	e := New(rules)
	out, hits := e.Apply("Authorization: Bearer abc123def456ghi789")
	if strings.Contains(out, "abc123def456ghi789") {
		t.Fatalf("bearer token not redacted: %q", out)
	}
	if len(hits) == 0 {
		t.Fatal("expected at least one hit")
	}
}

func TestEngine_DefaultRulesCommonSecrets(t *testing.T) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	e := New(rules)

	emisarAPIKey := "emk-" + strings.Repeat("a", 43)
	emisarRunnerToken := "rnrtok-" + strings.Repeat("b", 43)
	emisarAuthKey := "emkey-auth-" + strings.Repeat("c", 43)
	jwt := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature12345"
	githubPAT := "github_pat_" + strings.Repeat("A", 82)
	openAIKey := "sk-proj-" + strings.Repeat("A", 30)

	tests := []struct {
		name      string
		input     string
		leak      string
		validJSON bool
	}{
		{
			name:  "basic auth header",
			input: "Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
			leak:  "QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
		},
		{
			name:  "raw jwt",
			input: "token=" + jwt,
			leak:  jwt,
		},
		{
			name:  "emisar api key",
			input: "api key " + emisarAPIKey,
			leak:  emisarAPIKey,
		},
		{
			name:  "emisar runner token",
			input: "runner token " + emisarRunnerToken,
			leak:  emisarRunnerToken,
		},
		{
			name:  "emisar auth key",
			input: "auth key " + emisarAuthKey,
			leak:  emisarAuthKey,
		},
		{
			name:  "aws temporary access key",
			input: "AWS_ACCESS_KEY_ID=ASIA1234567890ABCDEF",
			leak:  "ASIA1234567890ABCDEF",
		},
		{
			name:  "aws secret access key assignment",
			input: "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
			leak:  "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
		},
		{
			name:  "prefixed secret assignment",
			input: "DATABASE_PASSWORD=hunter2",
			leak:  "hunter2",
		},
		{
			name:  "github fine grained token",
			input: "GITHUB_TOKEN=" + githubPAT,
			leak:  githubPAT,
		},
		{
			name:  "gitlab token",
			input: "gitlab glpat-" + strings.Repeat("A", 20),
			leak:  "glpat-" + strings.Repeat("A", 20),
		},
		{
			name:  "slack token",
			input: "slack xoxb-123456789012-123456789012-abcdefghijklmnopqrstuv",
			leak:  "xoxb-123456789012-123456789012-abcdefghijklmnopqrstuv",
		},
		{
			name:  "stripe secret key",
			input: "STRIPE_SECRET_KEY=sk_live_" + strings.Repeat("a", 24),
			leak:  "sk_live_" + strings.Repeat("a", 24),
		},
		{
			name:  "openai project key",
			input: "OPENAI_API_KEY=" + openAIKey,
			leak:  openAIKey,
		},
		{
			name:  "anthropic api key",
			input: "ANTHROPIC_API_KEY=sk-ant-api03-" + strings.Repeat("A", 30),
			leak:  "sk-ant-api03-" + strings.Repeat("A", 30),
		},
		{
			name:  "google api key",
			input: "GOOGLE_API_KEY=AIza" + strings.Repeat("A", 35),
			leak:  "AIza" + strings.Repeat("A", 35),
		},
		{
			name:  "npm token",
			input: "NPM_TOKEN=npm_" + strings.Repeat("a", 36),
			leak:  "npm_" + strings.Repeat("a", 36),
		},
		{
			name:  "sendgrid api key",
			input: "SENDGRID_API_KEY=SG." + strings.Repeat("A", 22) + "." + strings.Repeat("B", 43),
			leak:  "SG." + strings.Repeat("A", 22) + "." + strings.Repeat("B", 43),
		},
		{
			name:  "pgp private key block",
			input: "-----BEGIN PGP PRIVATE KEY BLOCK-----\nsecret\n-----END PGP PRIVATE KEY BLOCK-----",
			leak:  "secret",
		},
		{
			name:  "url credentials",
			input: "postgres://alice:s3cr3t@example.com/db",
			leak:  "alice:s3cr3t",
		},
		{
			name:  "cookie header",
			input: "Set-Cookie: session=s3cr3t; Path=/",
			leak:  "s3cr3t",
		},
		{
			name:      "json secret field",
			input:     `{"db_password":"tok_value","ok":true}`,
			leak:      "tok_value",
			validJSON: true,
		},
		{
			name:  "query param secret assignment",
			input: "otpauth://totp/emisar?secret=ABC123&issuer=emisar",
			leak:  "ABC123",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out, hits := e.Apply(tt.input)
			if strings.Contains(out, tt.leak) {
				t.Fatalf("secret was not redacted: %q", out)
			}
			if strings.Contains(out, "[REDACTED]]") {
				t.Fatalf("redacted placeholder was reprocessed: %q", out)
			}
			if len(hits) == 0 {
				t.Fatal("expected at least one hit")
			}
			if tt.validJSON && !json.Valid([]byte(out)) {
				t.Fatalf("redacted output is no longer valid JSON: %q", out)
			}
		})
	}
}

func TestEngine_ExtendPreservesOrder(t *testing.T) {
	global, err := CompileAll([]actionspec.RedactionRule{
		{Name: "global", Type: "literal", Literal: "GLOBAL", Replacement: "[G]"},
	})
	if err != nil {
		t.Fatal(err)
	}
	local, err := CompileAll([]actionspec.RedactionRule{
		{Name: "local", Type: "literal", Literal: "LOCAL", Replacement: "[L]"},
	})
	if err != nil {
		t.Fatal(err)
	}
	g := New(global)
	combined := g.Extend(local)
	out, _ := combined.Apply("see LOCAL and GLOBAL")
	if out != "see [L] and [G]" {
		t.Fatalf("got %q", out)
	}
}

func TestCompileRule_InvalidRegex(t *testing.T) {
	_, err := CompileRule(actionspec.RedactionRule{Name: "bad", Type: "regex", Pattern: "["})
	if err == nil {
		t.Fatal("expected compile error")
	}
}

func TestEmpty_NoRules(t *testing.T) {
	out, hits := Empty().Apply("anything")
	if out != "anything" || hits != nil {
		t.Fatalf("got %q %+v", out, hits)
	}
}
