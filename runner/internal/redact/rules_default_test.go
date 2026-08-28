package redact

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// defaultApply compiles the always-on DefaultRules and applies them to s,
// returning the redacted output and hit counts.
func defaultApply(t *testing.T, s string) (string, []Hit) {
	t.Helper()
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatalf("compiling default rules: %v", err)
	}
	return New(rules).Apply(s)
}

// every emisar credential prefix is masked by the always-on
// emisar-token rule (rules.go). The rule must keep pace with the portal
// credential format; this pins the exact prefix family and its marker, and
// asserts a near-miss prefix that is NOT in the format does not falsely match.
func TestDefaultRules_EmisarCredentialPrefixes(t *testing.T) {
	tail := strings.Repeat("aZ9_-", 9) // 45 base64url-ish chars, well over the 30 minimum

	masked := []struct {
		name  string
		value string
	}{
		{"operator api key (emk-)", "emk-" + tail},
		{"runner token (rnrtok-)", "rnrtok-" + tail},
		{"oauth access token (emo-)", "emo-" + tail},
		{"oauth refresh token (emor-)", "emor-" + tail},
		{"oauth authorization code (emoc-)", "emoc-" + tail},
		{"enrollment key (emkey-enroll-)", "emkey-enroll-" + tail},
		{"pre-rename enrollment key (emkey-auth-)", "emkey-auth-" + tail},
		{"pre-rebrand enrollment key (tskey-auth-)", "tskey-auth-" + tail},
	}
	for _, tc := range masked {
		t.Run(tc.name, func(t *testing.T) {
			// Neutral "issued " prefix carries no secret word and no =/:, so
			// only the emisar-token rule itself can fire — proving the prefix
			// pattern matches, not a fallback assignment/JSON rule.
			out, hits := defaultApply(t, "issued "+tc.value)
			if strings.Contains(out, tc.value) {
				t.Fatalf("emisar credential not redacted: %q", out)
			}
			if !strings.Contains(out, "[REDACTED_EMISAR_TOKEN]") {
				t.Fatalf("expected emisar-token marker, got %q", out)
			}
			if len(hits) != 1 || hits[0].Name != "emisar-token" {
				t.Fatalf("expected exactly the emisar-token rule to fire, got %+v", hits)
			}
		})
	}

	// Negative: a prefix that is NOT part of the emisar credential format must
	// not be swept up by the emisar-token rule. emo[rc]?- covers emo/emor/emoc;
	// "emrc-" is not a real prefix and must pass the emisar rule untouched.
	t.Run("non-format prefix not falsely matched", func(t *testing.T) {
		val := "emrc-" + tail
		out, hits := defaultApply(t, "issued "+val)
		for _, h := range hits {
			if h.Name == "emisar-token" {
				t.Fatalf("emisar-token rule should not match non-format prefix %q (out=%q)", val, out)
			}
		}
	})
}

// a PEM private-key block is masked as a whole via the
// non-greedy [\s\S]*? rule, on a single whole-buffer Apply (the streaming path
// is covered separately in stream_test.go). Both the generic PRIVATE KEY rule
// (rules.go:159) and the PGP block rule (rules.go:165) are exercised.
func TestDefaultRules_PEMAndPGPPrivateKeyBlock(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{
			name: "rsa private key",
			input: "key follows\n-----BEGIN RSA PRIVATE KEY-----\n" +
				"AAAALEAKYKEYBODYAAAA\nBBBBLEAKYKEYBODYBBBB\n" +
				"-----END RSA PRIVATE KEY-----\ndone",
		},
		{
			name: "ec private key with header words",
			input: "-----BEGIN EC PRIVATE KEY-----\n" +
				"ZZZZLEAKYKEYBODYZZZZ\n-----END EC PRIVATE KEY-----",
		},
		{
			name: "pgp private key block",
			input: "-----BEGIN PGP PRIVATE KEY BLOCK-----\n" +
				"QQQQLEAKYKEYBODYQQQQ\n-----END PGP PRIVATE KEY BLOCK-----",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := defaultApply(t, tc.input)
			if strings.Contains(out, "LEAKYKEYBODY") {
				t.Fatalf("private-key body leaked: %q", out)
			}
			if !strings.Contains(out, "[REDACTED_PRIVATE_KEY]") {
				t.Fatalf("expected private-key marker, got %q", out)
			}
			if len(hits) == 0 {
				t.Fatal("expected a hit for the private-key block")
			}
		})
	}
}

// URL inline credentials and both Cookie and Set-Cookie headers
// are masked. The existing common-secrets test covers url-credentials and
// Set-Cookie; this adds the plain "Cookie:" request header (the cookie-header
// rule matches both directions, rules.go:177) and asserts the URL scheme/host
// survive so only the secret is removed.
func TestDefaultRules_URLCredentialsAndCookieHeaders(t *testing.T) {
	t.Run("url credentials masked, scheme and host preserved", func(t *testing.T) {
		out, hits := defaultApply(t, "redis://admin:hunter2pw@cache.internal:6379/0")
		if strings.Contains(out, "hunter2pw") || strings.Contains(out, "admin:") {
			t.Fatalf("url credentials leaked: %q", out)
		}
		if !strings.Contains(out, "redis://") || !strings.Contains(out, "@cache.internal:6379/0") {
			t.Fatalf("url scheme/host should be preserved: %q", out)
		}
		if len(hits) == 0 {
			t.Fatal("expected a url-credentials hit")
		}
	})

	t.Run("request Cookie header masked", func(t *testing.T) {
		out, hits := defaultApply(t, "Cookie: sid=abc123sessiontoken; theme=dark")
		if strings.Contains(out, "abc123sessiontoken") {
			t.Fatalf("Cookie value leaked: %q", out)
		}
		if !strings.HasPrefix(out, "Cookie: [REDACTED]") {
			t.Fatalf("expected masked Cookie header, got %q", out)
		}
		if len(hits) == 0 {
			t.Fatal("expected a cookie-header hit")
		}
	})

	t.Run("response Set-Cookie header masked", func(t *testing.T) {
		out, _ := defaultApply(t, "Set-Cookie: session=topsecretvalue; Path=/; HttpOnly")
		if strings.Contains(out, "topsecretvalue") {
			t.Fatalf("Set-Cookie value leaked: %q", out)
		}
		if !strings.HasPrefix(out, "Set-Cookie: [REDACTED]") {
			t.Fatalf("expected masked Set-Cookie header, got %q", out)
		}
	})
}

// the generic secret-assignment and json-secret-field rules mask
// the value, match the field name case-insensitively, and tolerate the
// (?:[A-Za-z0-9]+[._-])* / (?:[._-][A-Za-z0-9]+)* affixes around the core
// secret word (rules.go:59-60,181-190).
func TestDefaultRules_SecretFieldAndAssignment(t *testing.T) {
	tests := []struct {
		name  string
		input string
		leak  string
	}{
		{"bare assignment with spaces", "api_secret = mytopsecretvalue", "mytopsecretvalue"},
		{"uppercase name", "DB_PASSWORD=hunter2pw", "hunter2pw"},
		{"prefixed affix", "app_access_token=zzztokenvaluezzz", "zzztokenvaluezzz"},
		{"suffixed affix", "client_secret_v2=shhdonttell", "shhdonttell"},
		{"single-quoted value", "refresh_token='quotedsecret'", "quotedsecret"},
		{"json field mixed case", `{"Api_Key":"jsontokvalue","ok":1}`, "jsontokvalue"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := defaultApply(t, tc.input)
			if strings.Contains(out, tc.leak) {
				t.Fatalf("secret value not redacted: %q", out)
			}
			if len(hits) == 0 {
				t.Fatalf("expected a hit for %q", tc.input)
			}
		})
	}
}

// a rule with an empty Name is rejected at compile.
func TestCompileRule_MissingName(t *testing.T) {
	_, err := CompileRule(actionspec.RedactionRule{Type: "regex", Pattern: "x"})
	if err == nil {
		t.Fatal("expected compile error for missing name")
	}
}

// a regex rule without a Pattern, and a literal rule without a
// Literal, are each rejected at compile (rules.go:31,43).
func TestCompileRule_MissingPatternOrLiteral(t *testing.T) {
	if _, err := CompileRule(actionspec.RedactionRule{Name: "r", Type: "regex"}); err == nil {
		t.Fatal("expected compile error for regex rule without pattern")
	}
	if _, err := CompileRule(actionspec.RedactionRule{Name: "r", Type: "literal"}); err == nil {
		t.Fatal("expected compile error for literal rule without literal")
	}
}

// an unknown rule Type is rejected at compile (rules.go:52).
func TestCompileRule_UnknownType(t *testing.T) {
	if _, err := CompileRule(actionspec.RedactionRule{Name: "r", Type: "glob", Pattern: "x"}); err == nil {
		t.Fatal("expected compile error for unknown rule type")
	}
}

// a credential whose shape matches none of the default patterns
// passes through unredacted. This is the documented best-effort limitation:
// default redaction is a last-resort net, not a guarantee — action authors must
// declare action-local rules for novel secret shapes (rules.go notes).
func TestDefaultRules_NovelSecretShapePassesThrough(t *testing.T) {
	// A token-like value with no secret keyword, no recognized prefix, and not
	// inside an assignment/JSON-field shape any default rule keys on.
	novel := "widget 7f3a9c2e8b1d4506aa11bb22"
	out, hits := defaultApply(t, novel)
	if out != novel {
		t.Fatalf("novel shape was altered (best-effort limitation expects pass-through): %q", out)
	}
	if hits != nil {
		t.Fatalf("expected no hits for a novel shape, got %+v", hits)
	}
}

// a rule with an empty Replacement defaults to [REDACTED] for
// both regex and literal rules (rules.go:38,47).
func TestCompileRule_EmptyReplacementDefaults(t *testing.T) {
	reRule, err := CompileRule(actionspec.RedactionRule{Name: "re", Type: "regex", Pattern: "[0-9]+"})
	if err != nil {
		t.Fatal(err)
	}
	litRule, err := CompileRule(actionspec.RedactionRule{Name: "lit", Type: "literal", Literal: "topsecret"})
	if err != nil {
		t.Fatal(err)
	}
	e := New([]Rule{reRule, litRule})
	out, _ := e.Apply("code 12345 and topsecret")
	if want := "code [REDACTED] and [REDACTED]"; out != want {
		t.Fatalf("empty replacement should default to [REDACTED]: got %q want %q", out, want)
	}
}

// the always-on default set covers the documented secret
// families and every rule compiles. Pins the count so a rule cannot be dropped
// silently, and checks each family is present by name (rules.go:55-57,62-191).
func TestDefaultRules_FamiliesPresentAndCompile(t *testing.T) {
	defs := DefaultRules()

	// Pin the count: the set is the documented last-resort net; an accidental
	// deletion (or an un-synced add) should trip this. There are 20 rules.
	if got := len(defs); got != 20 {
		t.Fatalf("DefaultRules count changed: got %d, want 20 (update this test deliberately if a rule was added/removed)", got)
	}

	want := []string{
		"bearer-token", "basic-auth", "jwt", "emisar-token",
		"aws-access-key", "github-token", "gitlab-token", "slack-token",
		"stripe-secret-key", "openai-api-key", "anthropic-api-key",
		"google-api-key", "npm-token", "sendgrid-api-key",
		"private-key-block", "pgp-private-key-block", "url-credentials",
		"cookie-header", "json-secret-field", "secret-assignment",
	}
	byName := make(map[string]bool, len(defs))
	for _, r := range defs {
		byName[r.Name] = true
	}
	for _, name := range want {
		if !byName[name] {
			t.Errorf("default rule family %q missing from DefaultRules", name)
		}
	}

	// Every default rule must compile — the always-on net is dead weight if any
	// member fails to compile at boot.
	if _, err := CompileAll(defs); err != nil {
		t.Fatalf("default rules must all compile: %v", err)
	}
}

// LiteralSet is the masking primitive for values that arrive with a run rather
// than from a reviewed pack. One rule, one pass — because as one rule per value
// they were applied in sequence, and a value that is a substring of the
// replacement then rewrote the marker an earlier value had left behind.
func TestLiteralSet_MasksInOnePass(t *testing.T) {
	tests := []struct {
		name      string
		literals  []string
		in        string
		want      string
		wantCount int
	}{
		{
			name:      "a literal inside the marker does not corrupt it",
			literals:  []string{"s3cr3t-alpha", "ED"},
			in:        "token=s3cr3t-alpha mode=ED",
			want:      "token=[REDACTED] mode=[REDACTED]",
			wantCount: 2,
		},
		{
			name:      "every substring of the marker stays inert",
			literals:  []string{"s3cr3t-alpha", "RED", "ACT", "REDACTED"},
			in:        "token=s3cr3t-alpha",
			want:      "token=[REDACTED]",
			wantCount: 1,
		},
		{
			name:      "an overlapping literal masks whole, longest first",
			literals:  []string{"abc", "abc123"},
			in:        "x abc123 y abc z",
			want:      "x [REDACTED] y [REDACTED] z",
			wantCount: 2,
		},
		{
			name:      "order of the input literals does not matter",
			literals:  []string{"abc123", "abc"},
			in:        "x abc123 y",
			want:      "x [REDACTED] y",
			wantCount: 1,
		},
		{
			name:      "repeated occurrences all mask",
			literals:  []string{"tok"},
			in:        "tok tok tok",
			want:      "[REDACTED] [REDACTED] [REDACTED]",
			wantCount: 3,
		},
		{
			name:      "no match leaves the text and count alone",
			literals:  []string{"absent"},
			in:        "nothing to see",
			want:      "nothing to see",
			wantCount: 0,
		},
		{
			name:      "a multi-byte literal masks and leaves its neighbours intact",
			literals:  []string{"café"},
			in:        "café and caffeine — naïve",
			want:      "[REDACTED] and caffeine — naïve",
			wantCount: 1,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rule := LiteralSet("sensitive-args", tc.literals, "[REDACTED]")
			got, hits := New([]Rule{rule}).Apply(tc.in)

			if got != tc.want {
				t.Fatalf("Apply() = %q, want %q", got, tc.want)
			}
			count := 0
			for _, hit := range hits {
				count += hit.Count
			}
			if count != tc.wantCount {
				t.Fatalf("Apply() hit count = %d, want %d", count, tc.wantCount)
			}
		})
	}
}

func TestLiteralSet_IgnoresEmptyAndDuplicateLiterals(t *testing.T) {
	rule := LiteralSet("sensitive-args", []string{"", "tok", "tok", ""}, "[REDACTED]")

	got, hits := New([]Rule{rule}).Apply("tok and tok")
	if want := "[REDACTED] and [REDACTED]"; got != want {
		t.Fatalf("Apply() = %q, want %q", got, want)
	}
	if len(hits) != 1 || hits[0].Count != 2 {
		t.Fatalf("Apply() hits = %+v, want one hit with count 2", hits)
	}
}

// An empty set must not mask everything (an empty literal would otherwise match
// at every position).
func TestLiteralSet_EmptySetIsANoOp(t *testing.T) {
	rule := LiteralSet("sensitive-args", []string{""}, "[REDACTED]")

	got, hits := New([]Rule{rule}).Apply("untouched")
	if got != "untouched" {
		t.Fatalf("Apply() = %q, want %q", got, "untouched")
	}
	if len(hits) != 0 {
		t.Fatalf("Apply() hits = %+v, want none", hits)
	}
}

// The secret-name list behind `json-secret-field` and `secret-assignment` is
// defence-in-depth: it catches a credential whose KEY names it. This pins the
// names added because they showed up in real config and matched nothing —
// connection URLs, key-derivation inputs, and signing keys — and, just as
// importantly, pins near-misses that must NOT be masked, because a rule that
// eats ordinary output teaches operators to distrust the redaction.
//
// Widening this list never justifies lowering an action's risk tier: a name
// nobody thought of still leaks. See
// .agent/kb/rules/packs-redaction-completeness-follows-a-closed-key-space.md.
func TestDefaultRules_WidenedSecretFieldNames(t *testing.T) {
	masked := []struct {
		name  string
		line  string
		leaks string
	}{
		{"dsn", `DSN=postgres-secret-value`, "postgres-secret-value"},
		{"connection_string", `connection_string: "Server=db;Pwd=s3cret"`, "s3cret"},
		{"database_url", `DATABASE_URL=mysql-conn-secret`, "mysql-conn-secret"},
		{"redis_url", `REDIS_URL=redis-conn-secret`, "redis-conn-secret"},
		{"smtp_url", `SMTP_URL=smtp-conn-secret`, "smtp-conn-secret"},
		{"passphrase", `passphrase = "unlock-me-please"`, "unlock-me-please"},
		{"secret_key_base", `secret_key_base: aVeryLongPhoenixSecret`, "aVeryLongPhoenixSecret"},
		{"signing_key", `signing_key=sign-this-value`, "sign-this-value"},
		{"encryption_key", `encryption_key: enc-this-value`, "enc-this-value"},
		{"cookie_key", `cookie_key=cookie-secret-value`, "cookie-secret-value"},
		{"salt", `salt: "per-user-salt-value"`, "per-user-salt-value"},
		{"pepper", `pepper=global-pepper-value`, "global-pepper-value"},
		{"credentials", `credentials: base64blobvalue`, "base64blobvalue"},
		{"json dsn field", `{"dsn": "postgres://u:p@h/db"}`, "postgres://u:p@h/db"},
		{"prefixed", `app.database_url=prefixed-secret`, "prefixed-secret"},
		// Glued names: no separator between the prefix and the secret word. The
		// prefix group used to REQUIRE one, so DB_PASSWORD was masked and
		// PGPASSWORD — Postgres's own credential variable — was not.
		{"PGPASSWORD", `PGPASSWORD=pg-secret-value`, "pg-secret-value"},
		{"DBPASSWORD", `DBPASSWORD=db-secret-value`, "db-secret-value"},
		{"MYSQLPASSWORD", `MYSQLPASSWORD=my-secret-value`, "my-secret-value"},
		{"ADMINPASSWORD", `ADMINPASSWORD=admin-secret-value`, "admin-secret-value"},
		{"master_key", `RAILS_MASTER_KEY=rails-secret-value`, "rails-secret-value"},
	}

	for _, tc := range masked {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := defaultApply(t, tc.line)
			if strings.Contains(out, tc.leaks) {
				t.Fatalf("secret leaked through %s: %q", tc.name, out)
			}
			if len(hits) == 0 {
				t.Fatalf("expected a redaction hit for %s, got none", tc.name)
			}
		})
	}

	// Ordinary operational output that merely resembles a secret name. Masking
	// any of these would hide the diagnostic an operator asked for.
	untouched := []struct {
		name string
		line string
	}{
		{"saltstack minion id", `minion: salted-web-01 responded in 12ms`},
		{"desalination hostname", `host=desalination-plant-01 status=ok`},
		{"credential count metric", `credentials_total 42`},
		{"url without userinfo", `redis://cache.internal:6379/0 connected`},
		{"prose mentioning salt", `Rotated the salt for every user last Tuesday.`},
		// The glued-prefix widening above must not reach these. A bare `key` or
		// `auth` is deliberately NOT a secret word for exactly this reason: these
		// are the ordinary output an operator ran the action to read.
		{"cache key", `cache_key=user:42`},
		{"primary key", `primary_key=id`},
		{"partition key", `partition_key=tenant`},
		{"object key", `object_key=uploads/a.png`},
		{"auth method", `auth_method=oidc`},
		{"auth toggle", `auth=enabled`},
		{"keyspace", `keyspace=analytics`},
		{"tokenizer", `tokenizer=standard`},
	}

	for _, tc := range untouched {
		t.Run("untouched/"+tc.name, func(t *testing.T) {
			out, _ := defaultApply(t, tc.line)
			if out != tc.line {
				t.Fatalf("ordinary output was redacted:\n  in:  %q\n  out: %q", tc.line, out)
			}
		})
	}
}
