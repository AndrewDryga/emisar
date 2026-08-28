package capture

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

// Shared browser-interaction helpers for the IdP capture rigs.
//
// Four rigs had hand-copied these and the copies drifted the same way readEnv's
// did: google's waitForText grew a null-guard for mid-navigation pages that
// entra's never got, okta's clickText matched input[type=button] where
// jumpcloud's did not, and each describePage dumped a different subset of the
// diagnostics. Every body here is the SUPERSET of the variants it replaced —
// extra selector coverage and extra failure diagnostics are never wrong for a
// capture rig. The deliberately per-vendor helpers (typeRealKeys, focusField,
// fillField, signIn, dismissOverlays) stay in their rigs: their differences are
// tuned to each console's widgets, not rot.

// ClickText clicks the first visible control whose trimmed label matches
// exactly, and reports whether it found one. Vendor consoles have few stable
// hooks, so the visible label is the most durable selector available.
func ClickText(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const target = [...document.querySelectorAll('a,button,input[type=submit],input[type=button],[role=button]')]
    .find(el => visible(el) && ((el.textContent || el.value || '').trim() === %q));
  if (!target) return false;
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
})()`, label)
	var clicked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked)); err != nil {
		return false, err
	}
	return clicked, nil
}

// ClickContaining clicks the SMALLEST visible element whose text contains the
// label. Rows and cards bundle subtitles and status text into one clickable
// node, so exact matching misses them; smallest-first avoids clicking a whole
// container.
func ClickContaining(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const candidates = [...document.querySelectorAll('a,button,li,tr,div,span,td,[role=option],[role=button],[role=menuitem]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!candidates.length) return false;
  candidates.sort((a, b) => a.textContent.length - b.textContent.length);
  const target = candidates[0];
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
})()`, label)
	var clicked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked)); err != nil {
		return false, err
	}
	return clicked, nil
}

// WaitForText polls the rendered page until needle shows up or the timeout
// passes, reporting whether it appeared. The SPA consoles keep one URL across
// whole flows, so text is the only honest signal a step advanced. Reporting
// rather than erroring leaves the caller to say what was missing — a bare
// timeout reads as a selector bug and sends the next reader hunting the wrong
// thing. The body null-guard is load-bearing: mid-navigation there is no body,
// and evaluating innerText on it threw in every rig that lacked the guard.
func WaitForText(ctx context.Context, needle string, timeout time.Duration) (bool, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body ? document.body.innerText : ""`, &body)); err != nil {
			return false, err
		}
		if strings.Contains(body, needle) {
			return true, nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
			return false, err
		}
	}
	return false, nil
}

// RequireText is WaitForText for callers that treat absence as failure.
func RequireText(ctx context.Context, needle string, timeout time.Duration) error {
	found, err := WaitForText(ctx, needle, timeout)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("timed out waiting for %q", needle)
	}
	return nil
}

// DescribePage prints what the console is actually showing — URL, visible text,
// form fields, and clickable controls — so a failed step is diagnosed from the
// real screen rather than a guess about it.
//
// secrets holds values that must never reach the dump (credentials from the
// rig's env). Only google's copy redacted before this was shared; the other
// rigs printed whatever the page showed, and a console page that echoes a
// secret would have landed it in the terminal and in CI logs.
func DescribePage(ctx context.Context, secrets map[string]string) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return JSON.stringify({
    url: location.origin + location.pathname,
    text: (document.body ? document.body.innerText : '').replace(/\n{2,}/g, "\n").slice(0, 1200),
    fields: [...document.querySelectorAll('input,textarea,select')].filter(visible)
      .map(el => [el.tagName, el.type || '', el.name || '-', el.placeholder || '-', el.getAttribute('aria-label') || '-'].join(' | ')),
    controls: [...new Set([...document.querySelectorAll('a,button,input[type=submit],[role=button],[role=tab],[role=radio]')]
      .filter(visible).map(el => (el.textContent || el.value || '').trim()).filter(Boolean))].slice(0, 60)
  }, null, 1);
})()`
	var described string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &described)); err != nil {
		return err
	}
	for _, value := range secrets {
		if len(value) >= 4 {
			described = strings.ReplaceAll(described, value, "[REDACTED]")
		}
	}
	fmt.Println("--- page ---")
	fmt.Println(described)
	return nil
}

// Highlight outlines the smallest visible element carrying the label, so a
// walkthrough screenshot shows WHERE to click. Emerald is emisar's accent, so
// the marker reads as ours rather than as part of the vendor UI. The search
// walks shadow roots — JumpCloud's console renders rows inside web components,
// and a document-only query finds nothing there; the walk is a no-op on pages
// without them. The ring lands on the row/control containing the text, not the
// text node itself (`closest` treats its list as one selector, so order in it
// carries no meaning). settle holds the page still long enough for the outline
// to paint before the caller screenshots.
//
// FAIL on a miss, never warn: a highlight that matched nothing ships a
// screenshot with no outline, which is a broken instruction rather than a
// cosmetic miss. One reached the docs that way.
func Highlight(ctx context.Context, label string, settle time.Duration) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const roots = [document];
  for (let index = 0; index < roots.length; index++) {
    for (const el of roots[index].querySelectorAll('*')) if (el.shadowRoot) roots.push(el.shadowRoot);
  }
  const matches = roots.flatMap(root => [...root.querySelectorAll('a,button,li,div,span,td,label,[role=option]')])
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  const target = matches[0].closest('label,li,tr,[role=option],a,button') || matches[0];
  target.style.outline = '3px solid #10b981';
  target.style.outlineOffset = '3px';
  target.style.borderRadius = '6px';
  target.scrollIntoView({block: 'center'});
  return true;
})()`, label)
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return fmt.Errorf("nothing matching %q to highlight", label)
	}
	fmt.Printf("  highlighted %q\n", label)
	return chromedp.Run(ctx, chromedp.Sleep(settle))
}
