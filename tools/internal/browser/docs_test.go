//go:build !windows

package browser

import (
	"context"
	"encoding/json"
	"image/png"
	"math"
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
		_, _ = w.Write([]byte(`<!doctype html><style>body{margin:0;background:#00ff00}.spacer{height:1800px}.deferred{content-visibility:auto;contain-intrinsic-size:auto 180px}.deferred>div{height:100px}#crop{margin-left:25vw;width:50vw;height:120px;background:linear-gradient(#ff0000 50%,#0000ff 50%);outline:2px solid #ffff00}</style><div class="spacer"></div><div class="deferred"><div></div></div><div id="crop"></div><div class="spacer"></div>`))
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
	if _, err := captureDocElement(session, DocsConfig{Temp: dir}, shot{Name: "edges", Anchor: Anchor{Selector: "#crop"}, CropPadding: 4}); err != nil {
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
	if bounds.Dx() != 816 || bounds.Dy() != 256 {
		t.Fatalf("crop bounds = %v", bounds)
	}
	red, green, blue, _ := picture.At(408, 10).RGBA()
	if red != 65535 || green != 0 || blue != 0 {
		t.Fatal("top of crop was lost")
	}
	red, green, blue, _ = picture.At(408, 245).RGBA()
	if red != 0 || green != 0 || blue != 65535 {
		t.Fatal("bottom of crop was lost")
	}
	for _, x := range []int{6, 810} {
		red, green, blue, _ = picture.At(x, 128).RGBA()
		if red != 65535 || green != 65535 || blue != 0 {
			t.Fatalf("outline at x=%d was clipped", x)
		}
	}

	// Console crops sit inside a flexible shell and a two-column editor. Check
	// all four corners and the outside padding after changing that viewport too.
	if err := session.Viewport(1680, 2800, 2, false); err != nil {
		t.Fatal(err)
	}
	if err := chromedp.Run(session.Context, chromedp.Evaluate(`document.documentElement.innerHTML=
	'<head><style>*{box-sizing:border-box}body{margin:0;background:#00ff00}.shell{display:flex}.sidebar{width:256px;flex:none;position:sticky;top:0}.canvas{flex:1;min-width:0}.content{overflow-x:clip;padding:32px}.editor{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:48px;padding-top:432.5px}#nested-crop{height:467px;border:4px solid #ffff00;background:#ff0000}footer{height:2000px}</style></head><body><div class="shell"><aside class="sidebar"></aside><div class="canvas"><main class="content"><div class="editor"><main><div id="nested-crop"></div><footer></footer></main><aside></aside></div></main></div></div></body>'`, nil)); err != nil {
		t.Fatal(err)
	}
	if err := session.Viewport(1440, 2800, 2, false); err != nil {
		t.Fatal(err)
	}
	if _, err := captureDocElement(session, DocsConfig{Temp: dir}, shot{Name: "nested", Anchor: Anchor{Selector: "#nested-crop"}, CropPadding: 4}); err != nil {
		t.Fatal(err)
	}
	nestedFile, err := os.Open(filepath.Join(dir, "nested.png"))
	if err != nil {
		t.Fatal(err)
	}
	defer nestedFile.Close()
	nested, err := png.Decode(nestedFile)
	if err != nil {
		t.Fatal(err)
	}
	if nested.Bounds().Dx() != 1480 || nested.Bounds().Dy() != 950 {
		t.Fatalf("nested crop bounds = %v", nested.Bounds())
	}
	for _, point := range [][2]int{{10, 10}, {1469, 10}, {10, 939}, {1469, 939}} {
		r, g, b, _ := nested.At(point[0], point[1]).RGBA()
		if r != 65535 || g != 65535 || b != 0 {
			t.Fatalf("nested crop lost corner %v", point)
		}
	}
	for _, point := range [][2]int{{2, 475}, {1477, 475}, {740, 2}, {740, 947}} {
		r, g, b, _ := nested.At(point[0], point[1]).RGBA()
		if r != 0 || g != 65535 || b != 0 {
			t.Fatalf("nested crop lost padding %v", point)
		}
	}

	// A real run with arguments reaches farther down than the old loop crop.
	// The overlay coordinates must use the same height as the exported frames.
	var targetsJSON string
	if err := chromedp.Run(session.Context,
		chromedp.Evaluate(`document.body.innerHTML='<div id="shell-canvas" style="width:1280px"><div style="height:1180px"></div><div data-shot="run-output" style="height:120px"></div></div>'`, nil),
		chromedp.Evaluate(loopTargets, &targetsJSON)); err != nil {
		t.Fatal(err)
	}
	var targets struct {
		Output struct{ Y, H float64 } `json:"output_rect"`
	}
	if err := json.Unmarshal([]byte(targetsJSON), &targets); err != nil {
		t.Fatal(err)
	}
	if targets.Output.Y+targets.Output.H > 100 {
		t.Fatal("loop output is clipped by the frame")
	}
	for _, frame := range loopFrames {
		wantY := math.Round(1180.0/float64(frame.TopCSS)*1000) / 10
		if targets.Output.Y != wantY {
			t.Fatalf("%s overlay y = %v, want %v for its crop", frame.Name, targets.Output.Y, wantY)
		}
	}
}
