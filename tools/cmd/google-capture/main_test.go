package main

import (
	"net/url"
	"strings"
	"testing"
)

func TestCheckLanding(t *testing.T) {
	begin, err := url.Parse("https://app.emisar.test/sign_in/sso/begin?provider=google")
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name     string
		location string
		ok       bool
	}{
		{"emisar landing route", "https://app.emisar.test/console", true},
		{"emisar root", "https://app.emisar.test/", true},
		{"stuck on the Google chooser", "https://accounts.google.com/v3/signin/accountchooser?hl=en", false},
		{"stuck on Google consent", "https://accounts.google.com/o/oauth2/v2/auth?client_id=x", false},
		{"unrelated origin", "https://example.com/console", false},
		{"deceptive hostname prefix", "https://app.emisar.test.evil.example/console", false},
		{"other scheme", "http://app.emisar.test/console", false},
		{"malformed URL", "://not a url", false},
		{"empty location", "", false},
		{"emisar sign-in route", "https://app.emisar.test/sign_in", false},
		{"emisar sso sign-in route", "https://app.emisar.test/sign_in/sso/callback?error=denied", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := checkLanding(begin, tt.location)
			if (err == nil) != tt.ok {
				t.Fatalf("checkLanding(%q) = %v, want ok=%v", tt.location, err, tt.ok)
			}
		})
	}
}

func TestDeidentifyReplacementsRedactsTestUserOnPrimaryDomain(t *testing.T) {
	env := map[string]string{
		"GOOGLE_TEST_USER":      "zq-founder@corp.test",
		"GOOGLE_CLIENT_ID":      "",
		"GOOGLE_CLIENT_SECRET":  "",
		"GOOGLE_PRIMARY_DOMAIN": "corp.test",
	}
	text := "signed in as zq-founder@corp.test; help help@corp.test; support support@corp.test; site corp.test"
	want := "signed in as admin@example.com; help help@example.com; support support@example.com; site example.com"

	// Every call yields the same order, and applying it the way the page script
	// does (split/join in order) leaves no real local part behind.
	first := deidentifyReplacements(env)
	for range 20 {
		pairs := deidentifyReplacements(env)
		if len(pairs) != len(first) {
			t.Fatalf("pair count changed: %v vs %v", pairs, first)
		}
		for i := range pairs {
			if pairs[i] != first[i] {
				t.Fatalf("order changed: %v vs %v", pairs, first)
			}
		}
		got := text
		for _, pair := range pairs {
			got = strings.ReplaceAll(got, pair[0], pair[1])
		}
		if got != want {
			t.Fatalf("deidentified text = %q, want %q", got, want)
		}
	}
	for _, pair := range first {
		if pair[0] == "" {
			t.Fatalf("empty source value kept: %v", first)
		}
	}
}
