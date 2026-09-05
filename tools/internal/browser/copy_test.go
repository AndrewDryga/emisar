//go:build !windows

package browser

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/chromedp/cdproto/runtime"
	"github.com/chromedp/chromedp"
)

// Exercise the module shipped by both Portal bundles in a real DOM. Only the
// clipboard and clock are fake: deterministic failures and overlapping clicks
// must not depend on the host clipboard, browser permissions, or wall time.
func TestCopyDelegation(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal(err)
		}
		t.Skip(err)
	}
	source, err := os.ReadFile("../../../portal/apps/emisar_web/assets/js/copy.js")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/copy.js" {
			w.Header().Set("Content-Type", "text/javascript")
			_, _ = w.Write(source)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(copyFixture))
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	session, err := New(Config{InBox: testInBox()}).isolatedSessionWithOptions(ctx, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	for _, test := range []struct{ name, script string }{
		{"literal bytes and nested click", `
await click(document.querySelector('#one .icon'));
assert(copies[0] === ' command\n\t<&>"  \n', JSON.stringify(copies));
assert(navigations === 0, 'copy activated enclosing navigation');
assert(one.textContent === 'Copied', 'success feedback missing');
advance(1500);
assert(one.querySelector('.icon') && one.textContent === ' Copy', 'original nodes lost');
`},
		{"repeated clicks and independent buttons", `
await click(one);
advance(1000);
await click(one);
await click(two);
advance(500);
assert(one.textContent === 'Copied', 'old timer restored too early');
assert(two.textContent === 'Saved', 'custom feedback missing');
advance(1000);
assert(one.querySelector('.icon') && one.textContent === ' Copy', 'repeated click lost original nodes');
assert(two.textContent === 'Second', 'second button did not restore');
await click(one);
advance(1500);
assert(one.querySelector('.icon') && one.textContent === ' Copy', 'later cycle did not restore');
`},
		{"clipboard failure and fallback", `
clipboardFails = true;
fallbackOK = false;
await click(one);
assert(one.querySelector('.icon') && one.textContent === ' Copy', 'failed copy claimed success');
assert(document.querySelector('textarea') === null, 'fallback textarea leaked');
fallbackOK = true;
await click(one);
assert(fallbackCopies.at(-1) === ' command\n\t<&>"  \n', 'fallback changed bytes');
assert(one.textContent === 'Copied', 'fallback success missing');
advance(1500);
assert(one.querySelector('.icon') && one.textContent === ' Copy', 'fallback did not restore');
`},
		{"selector compatibility and empty target", `
await click(document.querySelector('#selector'));
assert(copies[0] === 'first\n  second', JSON.stringify(copies));
await click(document.querySelector('#empty'));
assert(copies.length === 1, 'empty content copied');
assert(document.querySelector('#empty').textContent === 'Empty', 'empty content flashed');
`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := session.Navigate("/"); err != nil {
				t.Fatal(err)
			}
			if err := chromedp.Run(session.Context, chromedp.Poll("window.copyReady === true", nil)); err != nil {
				t.Fatal(err)
			}
			script := `(async () => {
const assert = (ok, message) => { if (!ok) throw new Error(message) };
const one = document.querySelector('#one'), two = document.querySelector('#two');
const click = async element => { element.click(); await Promise.resolve(); await Promise.resolve(); };
` + test.script + `})()`
			if err := chromedp.Run(session.Context, chromedp.Evaluate(script, nil,
				func(p *runtime.EvaluateParams) *runtime.EvaluateParams { return p.WithAwaitPromise(true) })); err != nil {
				t.Fatal(err)
			}
		})
	}
}

const copyFixture = `<!doctype html><html><body>
<a id="row" href="/unexpected"><button id="one" data-copy-text=" command&#10;&#9;&lt;&amp;&gt;&quot;  &#10;"><span class="icon" aria-hidden="true"></span> Copy</button></a>
<button id="two" data-copy-text="second" data-copy-label-copied="Saved">Second</button>
<pre id="code">$ display is not clipboard content</pre>
<pre id="indented">  first
    second&#32;&#32;
</pre>
<button id="selector" data-copy="#indented">Selector</button>
<button id="empty" data-copy-text="">Empty</button>
<script type="module">
import {setupCopyToClipboardDelegation} from '/copy.js';
window.copies = []; window.fallbackCopies = []; window.navigations = 0;
window.clipboardFails = false; window.fallbackOK = true;
Object.defineProperty(navigator, 'clipboard', {value: {writeText: async text => {
  if (window.clipboardFails) throw new Error('clipboard denied');
  copies.push(text);
}}});
document.execCommand = command => {
  if (command !== 'copy') throw new Error('unexpected command');
  fallbackCopies.push(document.querySelector('textarea').value);
  return fallbackOK;
};
document.querySelector('#row').addEventListener('click', () => { navigations++ });
let now = 0, nextID = 0;
const timers = new Map();
window.setTimeout = (callback, delay) => { const id = ++nextID; timers.set(id, {callback, due: now + delay}); return id };
window.clearTimeout = id => timers.delete(id);
window.advance = elapsed => {
  now += elapsed;
  for (const [id, timer] of timers) if (timer.due <= now) { timers.delete(id); timer.callback() }
};
setupCopyToClipboardDelegation();
window.copyReady = true;
</script></body></html>`
