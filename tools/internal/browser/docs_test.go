//go:build !windows

package browser

import (
	"context"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

func TestDocsRecipesWaitForResolvedContent(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<!doctype html><html><body></body></html>"))
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	session, err := New(Config{InBox: testInBox()}).isolatedSessionWithOptions(ctx, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.Navigate("/"); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, html, script string
		want               bool
	}{
		{"missing plan", "", waitForResolvedRunbookPlan, false},
		{"loading plan", `<section id="current-runbook-plan">Checking current state</section>`, waitForResolvedRunbookPlan, false},
		{"summary alone is not ready", `<div id="current-runbook-plan-summary">Actions: 3</div>`, waitForResolvedRunbookPlan, false},
		{"unrelated stage is not ready", `<div id="preflight-stage-preview"></div><section id="current-runbook-plan"></section>`, waitForResolvedRunbookPlan, false},
		{"resolved plan", `<section id="current-runbook-plan"><div id="preflight-stage-check">Check configuration</div></section>`, waitForResolvedRunbookPlan, true},
		{"missing SCIM setup", "", openSCIMSetup, false},
		{"hidden panel is not open", `<button onclick="document.querySelector('#controls').hidden=false">Expand</button><div id="controls" hidden>Options</div>`, openPanel("button", "#controls"), false},
		{"visible panel is open", `<button>Collapse</button><div id="controls">Options</div>`, openPanel("button", "#controls"), true},
		{"open SCIM guide", `<details id="scim-setup-demo"><summary>Setup instructions</summary><p>Base URL</p></details>`, openSCIMSetup + ` && document.querySelector('details').open`, true},
		{"missing region", "", selectJumpCloudRegion, false},
		{"region notifies form", `<form onchange="this.dataset.region=event.target.value"><select name="provider[issuer]"><option value="">Select a region</option><option value="https://oauth.id.jumpcloud.com/">United States</option></select></form>`, selectJumpCloudRegion + ` && document.querySelector('form').dataset.region === 'https://oauth.id.jumpcloud.com/'`, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			html, err := json.Marshal(test.html)
			if err != nil {
				t.Fatal(err)
			}
			var got bool
			if err := chromedp.Run(session.Context,
				chromedp.Evaluate("document.body.innerHTML="+string(html), nil),
				chromedp.Evaluate(test.script, &got)); err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("recipe ready = %v, want %v", got, test.want)
			}
		})
	}
}

func TestDocsCropKeepsBothEdgesAfterViewportChange(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<!doctype html><style>body{margin:0;background:#00ff00}.spacer{height:1800px}.deferred{content-visibility:auto;contain-intrinsic-size:auto 180px}.deferred>div{height:100px}#crop{margin-left:25vw;width:50vw;height:120px;background:linear-gradient(#ff0000 50%,#0000ff 50%)}</style><div class="spacer"></div><div class="deferred"><div></div></div><div id="crop"></div><div class="spacer"></div>`))
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	session, err := New(Config{InBox: testInBox()}).isolatedSessionWithOptions(ctx, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.Viewport(1280, 600, 2, false); err != nil {
		t.Fatal(err)
	}
	if err := session.Navigate("/"); err != nil {
		t.Fatal(err)
	}
	if err := session.Viewport(800, 600, 2, false); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if _, err := captureDocElement(session, DocsConfig{Temp: dir}, shot{Name: "edges", Anchor: Anchor{Selector: "#crop"}}); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(filepath.Join(dir, "edges.png"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	picture, err := png.Decode(file)
	if err != nil {
		t.Fatal(err)
	}
	bounds := picture.Bounds()
	if bounds.Dx() != 800 || bounds.Dy() != 240 {
		t.Fatalf("crop bounds = %v", bounds)
	}
	red, green, blue, _ := picture.At(400, 2).RGBA()
	if red != 65535 || green != 0 || blue != 0 {
		t.Fatal("top of crop was lost")
	}
	red, green, blue, _ = picture.At(400, 237).RGBA()
	if red != 0 || green != 0 || blue != 65535 {
		t.Fatal("bottom of crop was lost")
	}
}
