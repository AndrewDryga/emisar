package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/browser"
	"github.com/chromedp/chromedp"
)

// fixtureSession serves pages by path and opens a browser on them, skipping
// where no Chrome is installed.
func fixtureSession(t *testing.T, pages map[string]string) (context.Context, string) {
	t.Helper()
	if _, err := browser.ResolveChrome(); err != nil {
		t.Skip(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, "<!doctype html><body>%s</body>", pages[r.URL.Path])
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	session, err := browser.New(browser.Config{InBox: os.Getenv("COOP_BOX") == "1" || os.Getenv("CI") != ""}).Session(ctx, server.URL, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.Close)
	return session.Context, server.URL
}

// The in-console terms dialog can render after sign-in's own check, so the
// opt-in is enforced where Agree is clicked: without it nothing on the dialog is
// touched, with it the agreement is ticked and accepted.
func TestAcceptTermsRequiresTheCloudTOSOptIn(t *testing.T) {
	const dialog = `<div role="dialog"><label><input type="checkbox" id="agree"> I agree to the Google Cloud Platform Terms of Service</label>
<button onclick="document.body.dataset.agreed='yes'">Agree and continue</button></div>`
	ctx, origin := fixtureSession(t, map[string]string{
		"/dialog": dialog,
		// Arrives late, the way the console's dialog does.
		"/delayed": `<script>setTimeout(() => document.body.insertAdjacentHTML('beforeend', ` + "`" + dialog + "`" + `), 300)</script>`,
		"/plain":   `<a href="#">Terms of Service</a>`,
	})
	state := func() string {
		t.Helper()
		got, err := chromedp.Run(ctx, chromedp.Evaluate[string](`(document.getElementById('agree')?.checked ? 'ticked' : 'unticked') + '/' + (document.body.dataset.agreed || 'not agreed')`))
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	for _, tc := range []struct {
		path    string
		consent bool
		wantErr error
		want    string
	}{
		{"/dialog", false, errCloudTOSConsent, "unticked/not agreed"},
		{"/delayed", false, errCloudTOSConsent, "unticked/not agreed"},
		{"/plain", false, nil, "unticked/not agreed"},
		{"/dialog", true, nil, "ticked/yes"},
	} {
		if err := chromedp.Do(ctx, chromedp.Navigate(origin+tc.path), chromedp.Sleep(time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := acceptTerms(ctx, tc.consent); !errors.Is(err, tc.wantErr) {
			t.Errorf("%s consent=%v: error = %v, want %v", tc.path, tc.consent, err, tc.wantErr)
		}
		if got := state(); got != tc.want {
			t.Errorf("%s consent=%v: dialog state = %s, want %s", tc.path, tc.consent, got, tc.want)
		}
	}
}

// A docs run removes only its own client; the certification client's saved
// credentials stay usable until an explicit -cleanup, which counts both.
func TestCaptureClientCountsFollowTheCleanupScope(t *testing.T) {
	ctx, origin := fixtureSession(t, map[string]string{
		"/clients": `<table>
<tr><td><input type="checkbox"></td><td>emisar docs capture</td></tr>
<tr><td><input type="checkbox"></td><td>emisar login certification</td></tr>
<tr><td><input type="checkbox"></td><td>Production web client</td></tr>
</table>`,
	})
	if err := chromedp.Do(ctx, chromedp.Navigate(origin+"/clients")); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		names []string
		want  int
	}{
		{[]string{captureClientName}, 1},
		{[]string{captureClientName, certifyClientName}, 2},
	} {
		got, err := countCaptureClients(ctx, tc.names)
		if err != nil {
			t.Fatal(err)
		}
		if got != tc.want {
			t.Errorf("countCaptureClients(%q) = %d, want %d", tc.names, got, tc.want)
		}
	}
}

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
