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

func TestCodeInputRemountAcceptsNewAddressCode(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	source, err := os.ReadFile("../../../portal/apps/emisar_web/assets/js/code_input.js")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/code_input.js" {
			w.Header().Set("Content-Type", "text/javascript")
			_, _ = w.Write(source)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<!doctype html><form id="email"><div id="step"></div><button>Continue</button></form>
<script type="module">
import {CodeInput} from '/code_input.js';
const form = document.querySelector('form');
const submissions = [];
document.addEventListener('submit', event => {
  submissions.push({blocked: event.defaultPrevented, code: form.querySelector('[data-code]').value});
  event.preventDefault();
});
const mount = (id, numeric) => {
  const el = document.createElement('div');
  el.id = id;
  el.dataset.numeric = String(numeric);
  el.innerHTML = Array.from({length: 6}, () => '<input data-box maxlength="1">').join('') + '<input type="hidden" data-code>';
  document.querySelector('#step').replaceChildren(el);
  const handlers = {};
  const hook = Object.assign({el, handleEvent(name, callback) { handlers[name] = callback; }}, CodeInput);
  hook.mounted();
  return {hook, reset() { handlers['code:reset']({id}); }};
};
const paste = text => {
  const clipboardData = new DataTransfer();
  clipboardData.setData('text', text);
  form.querySelector('[data-box]').dispatchEvent(new ClipboardEvent('paste', {clipboardData, bubbles: true, cancelable: true}));
};
window.checkCodeTransition = () => {
  const current = mount('email-step-code', true);
  paste('123456');
  current.reset();
  // LiveView destroys the numeric hook while preserving the form. Its submit
  // listener must not keep rejecting the next hook's complete code.
  current.hook.destroyed();
  const next = mount('new-email-code', false);
  paste('aB2cD3');
  if (JSON.stringify(submissions) !== JSON.stringify([
    {blocked: false, code: '123456'}, {blocked: false, code: 'AB2CD3'}
  ])) throw new Error('code transition failed: ' + JSON.stringify(submissions));
  next.reset();
  paste('XY');
  form.requestSubmit();
  if (submissions.length !== 3 || !submissions[2].blocked) throw new Error('incomplete code was submitted');
  next.hook.destroyed();
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
		chromedp.Poll("typeof window.checkCodeTransition === 'function'", nil),
		chromedp.Evaluate("window.checkCodeTransition()", nil)); err != nil {
		t.Fatal(err)
	}
}
