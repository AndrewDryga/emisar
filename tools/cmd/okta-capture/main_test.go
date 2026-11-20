package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/browser"
	"github.com/chromedp/chromedp"
)

// A label that never lands creates the SCIM app under Okta's default name,
// which -cleanup cannot recognise. labelSCIMApp must stop the run instead.
func TestLabelSCIMAppRequiresTheLabelToLand(t *testing.T) {
	if _, err := browser.ResolveChrome(); err != nil {
		t.Skip(err)
	}
	pages := map[string]string{
		"/plain": `<label for="l">Application label</label><input id="l" name="label">`,
		"/none":  `<input name="search">`,
		// A controlled field that throws away whatever is set on it.
		"/reverts": `<input name="label" oninput="this.value=''">`,
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
	settle := func(int) error { return nil }

	for _, tc := range []struct {
		path    string
		wantErr string
	}{
		{"/plain", ""},
		{"/none", "field was not found"},
		{"/reverts", "did not take"},
	} {
		if err := chromedp.Do(session.Context, chromedp.Navigate(server.URL+tc.path)); err != nil {
			t.Fatal(err)
		}
		err := labelSCIMApp(session.Context, settle)
		switch {
		case tc.wantErr == "" && err != nil:
			t.Errorf("%s: unexpected error %v", tc.path, err)
		case tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)):
			t.Errorf("%s: error = %v, want one containing %q", tc.path, err, tc.wantErr)
		}
	}
}
