//go:build !windows

package browser

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

// A LiveView control inside a tooltip must reach the window's delegated click
// listener. Plain tooltip content must not activate the enclosing clickable row.
func TestTooltipDelegatedControls(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	sources := make(map[string][]byte)
	for _, name := range []string{"tooltip.js", "overlay.js"} {
		source, err := os.ReadFile("../../../portal/apps/emisar_web/assets/js/" + name)
		if err != nil {
			t.Fatal(err)
		}
		sources["/"+name] = source
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if source, ok := sources[r.URL.Path]; ok {
			w.Header().Set("Content-Type", "text/javascript")
			_, _ = w.Write(source)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<!doctype html><div phx-click="row">
<div id="tip"><span id="trigger">Update</span><div data-tooltip-bubble data-side="above">
<p id="plain">Install on the affected machine.</p>
<button phx-click="select_os"><span id="windows">Windows</span></button>
<a id="link" href="#activity" data-phx-link="patch">View activity</a>
</div></div></div><script type="module">
import {wireTooltip} from '/tooltip.js';
const unwire = wireTooltip(document.querySelector('#tip'));
const clicks = [];
// Match LiveView's window-level delegation, including a nested click target.
window.addEventListener('click', event => {
  const control = event.target.closest('[phx-click], [data-phx-link]');
  if (control) {
    event.preventDefault();
    clicks.push(control.getAttribute('phx-click') || control.getAttribute('data-phx-link'));
  }
});
window.checkTooltip = () => {
  document.querySelector('#windows').click();
  document.querySelector('#plain').click();
  document.querySelector('#link').click();
  if (JSON.stringify(clicks) !== JSON.stringify(['select_os', 'patch'])) {
    throw new Error('tooltip controls or row shielding failed: ' + JSON.stringify(clicks));
  }
  document.querySelector('#trigger').click();
  if (clicks.at(-1) !== 'row') throw new Error('trigger stopped activating its row');
  unwire();
  document.querySelector('#plain').click();
  if (clicks.length !== 4) throw new Error('tooltip did not remove its listener');
};
</script>`))
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
	if err := chromedp.Run(session.Context,
		chromedp.Poll("typeof window.checkTooltip === 'function'", nil),
		chromedp.Evaluate("window.checkTooltip()", nil)); err != nil {
		t.Fatal(err)
	}
}
