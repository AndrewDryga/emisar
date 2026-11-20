package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/browser"
	"github.com/chromedp/chromedp"
)

// The refuse-to-create guard counts exactly what -cleanup-apps deletes: a
// tenant holding only the certified keeper lets a fresh run start, and a
// leftover beside it is counted and selected while the keeper stays unticked.
func TestCreationGuardAndCleanupShareTheKeeperPredicate(t *testing.T) {
	if _, err := browser.ResolveChrome(); err != nil {
		t.Skip(err)
	}
	row := func(id, cells string) string {
		return fmt.Sprintf(`<div style="display:flex;gap:8px;height:32px;align-items:center"><input type="checkbox" id=%q>%s</div>`, id, cells)
	}
	keeper := row("keeper", `<span>emisar</span><span>Custom OIDC</span><span>Expires 2027-03-01</span>`)
	pages := map[string]string{
		"/keeper-only": keeper + row("other", `<span>Slack</span><span>SAML</span>`),
		"/leftover":    keeper + row("leftover", `<span>emisar</span><span>Custom OIDC</span><span>Provisioning</span>`),
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, "<!doctype html><body>%s</body>", pages[r.URL.Path])
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	session, err := browser.New(browser.Config{InBox: os.Getenv("COOP_BOX") == "1" || os.Getenv("CI") != ""}).Session(ctx, server.URL, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	for _, tc := range []struct {
		path      string
		wantCount int
		wantTicks string
	}{
		{"/keeper-only", 0, "keeper=false"},
		{"/leftover", 1, "keeper=false leftover=true"},
	} {
		if err := chromedp.Do(session.Context, chromedp.Navigate(server.URL+tc.path)); err != nil {
			t.Fatal(err)
		}
		count, err := chromedp.Run(session.Context, chromedp.Evaluate[int](countAbandonedApps))
		if err != nil {
			t.Fatal(err)
		}
		if count != tc.wantCount {
			t.Errorf("%s: guard counted %d, want %d", tc.path, count, tc.wantCount)
		}
		if _, err := chromedp.Run(session.Context, chromedp.Evaluate[string](selectAbandonedApps)); err != nil {
			t.Fatal(err)
		}
		ticks, err := chromedp.Run(session.Context, chromedp.Evaluate[string](
			`['keeper', 'leftover'].filter(id => document.getElementById(id)).map(id => id + '=' + document.getElementById(id).checked).join(' ')`))
		if err != nil {
			t.Fatal(err)
		}
		if ticks != tc.wantTicks {
			t.Errorf("%s: cleanup selection = %q, want %q", tc.path, ticks, tc.wantTicks)
		}
	}
}
