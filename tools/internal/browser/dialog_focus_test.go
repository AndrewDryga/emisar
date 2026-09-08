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

func TestDialogFocusReturnsToItsOpener(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	source, err := os.ReadFile("../../../portal/apps/emisar_web/assets/js/dialog_focus.js")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/dialog_focus.js" {
			w.Header().Set("Content-Type", "text/javascript")
			_, _ = w.Write(source)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<!doctype html><button id="opener">Link</button><script type="module">
import {DialogFocus} from '/dialog_focus.js';
window.checkDialog = serverRendered => {
  const opener = document.querySelector('#opener');
  opener.focus();
  const el = document.createElement('div');
  el.innerHTML = '<button>Cancel</button>';
  if (serverRendered) el.dataset.serverDialog = 'true';
  document.body.append(el);
  const hook = Object.assign({el}, DialogFocus);
  hook.mounted();
  if (!serverRendered) el.dispatchEvent(new Event('phx:show-start'));
  el.firstChild.focus();
  if (document.activeElement !== el.firstChild) throw new Error('dialog did not receive focus');
  if (serverRendered) { el.remove(); hook.destroyed(); }
  else { el.dispatchEvent(new Event('phx:hide-end')); hook.destroyed(); el.remove(); }
  if (document.activeElement !== opener) throw new Error('focus did not return to opener');
  return true;
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
	if err := chromedp.Run(session.Context, chromedp.Poll("typeof window.checkDialog === 'function'", nil)); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ name, script string }{
		{"server removal", "window.checkDialog(true)"},
		{"client hide", "window.checkDialog(false)"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := chromedp.Run(session.Context, chromedp.Evaluate(test.script, nil)); err != nil {
				t.Fatal(err)
			}
		})
	}
}
