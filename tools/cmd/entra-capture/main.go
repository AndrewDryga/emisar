// Command entra-capture drives a live Microsoft Entra tenant to produce the
// /docs/sso#entra walkthrough screenshots, the way okta-capture and
// jumpcloud-capture do for theirs.
//
// Entra's sign-in is a four-screen sequence (email → password → TOTP → "stay
// signed in"), each rendered by the same SPA, so every step waits on the NEXT
// field appearing rather than a fixed sleep.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/idpcapture"
	"github.com/chromedp/chromedp"

	"github.com/andrewdryga/emisar/tools/internal/capture"
)

func main() {
	env := flag.String("env", "portal/.agent/secrets/entra-trial.env", "env file with the tenant credentials")
	outDir := flag.String("out", "", "directory for the captured PNGs")
	headless := flag.Bool("headless", true, "run Chrome headless")
	formOnly := flag.Bool("form-only", false, "capture the filled registration form without creating an app")
	flag.Parse()

	// Required, and never defaulted to a shared /tmp path: the captures are of a
	// live IdP console, so they must land in a directory the operator chose.
	if *outDir == "" {
		fail(errors.New("-out is required"))
	}
	values, err := readEnv(*env)
	if err != nil {
		fail(err)
	}
	if err := os.MkdirAll(*outDir, 0o700); err != nil {
		fail(err)
	}
	if err := run(values, *outDir, *headless, *formOnly); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "entra-capture:", err)
	os.Exit(1)
}

// readEnv loads this rig's credentials, letting the process environment win
// for its per-run keys. The parser is shared so the four rigs cannot drift.
func readEnv(path string) (map[string]string, error) {
	return capture.ReadEnv(path)
}

func run(env map[string]string, outDir string, headless, formOnly bool) error {
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", headless),
		chromedp.WindowSize(1440, 1000),
	)
	allocator, cancelAllocator := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAllocator()

	ctx, cancel := chromedp.NewContext(allocator)
	defer cancel()
	ctx, cancelTimeout := context.WithTimeout(ctx, 12*time.Minute)
	defer cancelTimeout()

	if err := signIn(ctx, env, outDir); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "en-login-failed")
		_ = describePage(ctx)
		return err
	}
	fmt.Println("  signed in")
	if err := idpcapture.Screenshot(ctx, outDir, "en-01-signed-in"); err != nil {
		return err
	}
	return appRegistrationFlow(ctx, env, outDir, formOnly)
}

// signIn walks Microsoft's sign-in sequence. Every screen lives in ONE DOM that
// the SPA shows and hides, so a bare `input[type=submit]` matches the hidden
// email screen's button and silently submits nothing — that cost a debugging
// round. Click Microsoft's stable `#idSIButton9` and gate each step on the text
// of the screen that should now be showing, not on a field's mere presence.
func signIn(ctx context.Context, env map[string]string, outDir string) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://portal.azure.com/"),
		chromedp.WaitVisible(`input[name="loginfmt"]`, chromedp.ByQuery),
		chromedp.SendKeys(`input[name="loginfmt"]`, env["ENTRA_ADMIN_USER"], chromedp.ByQuery),
		chromedp.Click(`#idSIButton9`, chromedp.ByQuery),
	); err != nil {
		return fmt.Errorf("username step: %w", err)
	}
	if err := waitForText(ctx, "Enter password", 45*time.Second); err != nil {
		return fmt.Errorf("password screen never appeared: %w", err)
	}
	fmt.Println("  username accepted")

	if err := chromedp.Run(ctx,
		chromedp.SendKeys(`input[name="passwd"]`, env["ENTRA_ADMIN_PASSWORD"], chromedp.ByQuery),
		chromedp.Click(`#idSIButton9`, chromedp.ByQuery),
		chromedp.Sleep(5*time.Second),
	); err != nil {
		return fmt.Errorf("password step: %w", err)
	}
	fmt.Println("  password submitted")

	return settle(ctx, env)
}

// settle answers whatever Microsoft puts up next until the admin center is
// actually loaded. The order is NOT fixed — this tenant shows "Stay signed in?"
// BEFORE the authenticator challenge, and a single check for the code field ran
// too early and skipped an MFA prompt that did appear a moment later. So poll the
// screen and respond to whichever one is showing.
func settle(ctx context.Context, env map[string]string) error {
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}

		switch {
		case strings.Contains(body, "Enter code"), strings.Contains(body, "Enter the code displayed"):
			if err := submitTOTP(ctx, env); err != nil {
				return err
			}

		case strings.Contains(body, "Stay signed in?"):
			fmt.Println("  dismissing \"Stay signed in?\"")
			_ = chromedp.Run(ctx, chromedp.Click(`#idBtn_Back`, chromedp.ByQuery))
			_ = chromedp.Run(ctx, chromedp.Sleep(4*time.Second))

		case strings.Contains(body, "Create a resource"),
			strings.Contains(body, "Microsoft Entra admin center"),
			strings.Contains(body, "All resources"):
			fmt.Println("  portal loaded")
			return nil

		default:
			_ = chromedp.Run(ctx, chromedp.Sleep(3*time.Second))
		}
	}
	return fmt.Errorf("never reached the admin center")
}

func waitForText(ctx context.Context, want string, timeout time.Duration) error {
	return capture.RequireText(ctx, want, timeout)
}

// submitTOTP answers the authenticator prompt. The code is computed in-process
// from the enrolment secret; a code is only valid for its 30s window, so this
// waits for a fresh window rather than submitting one about to expire.
func submitTOTP(ctx context.Context, env map[string]string) error {
	secret := env["ENTRA_TOTP_SECRET"]
	if secret == "" {
		return fmt.Errorf("ENTRA_TOTP_SECRET is empty")
	}

	if remaining := 30 - time.Now().Unix()%30; remaining < 8 {
		fmt.Printf("  waiting %ds for a fresh TOTP window\n", remaining)
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Duration(remaining+1)*time.Second)); err != nil {
			return err
		}
	}

	code, err := capture.TOTPCode(secret)
	if err != nil {
		return err
	}
	fmt.Println("  submitting TOTP passcode")
	return chromedp.Run(ctx,
		chromedp.SendKeys(`input[name="otc"]`, code, chromedp.ByQuery),
		chromedp.Click(`input[type="submit"]`, chromedp.ByQuery),
		chromedp.Sleep(6*time.Second),
	)
}

func describePage(ctx context.Context) error {
	return capture.DescribePage(ctx, nil)
}

// appRegistrationFlow captures the sign-in half of the Entra walkthrough: the
// registration form with emisar's redirect URI, then the client secret. This is
// the half that works on a free tenant — provisioning needs P1.
func appRegistrationFlow(ctx context.Context, env map[string]string, outDir string, formOnly bool) error {
	// Registering again would mint yet another duplicate — seven accumulated before
	// the list blade's failure to render made them visible. With a client id in
	// hand, go straight to the saved app.
	if env["ENTRA_CLIENT_ID"] != "" && !formOnly {
		fmt.Println("  app already registered — skipping the create form")
		return openRegisteredApp(ctx, env, outDir)
	}
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade"),
		chromedp.Sleep(18*time.Second),
	); err != nil {
		return err
	}
	if err := idpcapture.Screenshot(ctx, outDir, "en-03-new-registration-blank"); err != nil {
		return err
	}

	// Fill the form BEFORE shooting — a walkthrough frame showing an empty
	// required field reads as though the field is optional.
	if err := fillField(ctx, "name", "emisar"); err != nil {
		fmt.Println("  WARN name:", err)
	}
	if err := fillField(ctx, "redirect", "https://emisar.dev/sign_in/sso/callback"); err != nil {
		fmt.Println("  WARN redirect:", err)
	}
	// The redirect URI is inert until a platform is chosen — leaving it unset
	// fails with "Platform is required", which is why the docs say to pick Web.
	if err := selectPlatform(ctx, "Web"); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "en-04-platform-failed")
		return err
	}
	if err := highlightRegistrationGroup(ctx); err != nil {
		return err
	}
	if err := idpcapture.Screenshot(ctx, outDir, "en-04-new-registration-filled"); err != nil {
		return err
	}
	if err := markRegistrationDocsViewport(ctx); err != nil {
		return err
	}
	if err := idpcapture.ScreenshotElement(ctx, outDir, "en-04-new-registration-filled-docs", "[data-emisar-docs-entra-registration=true]"); err != nil {
		return err
	}
	if formOnly {
		return nil
	}

	if err := clickTextAtCentre(ctx, "Register"); err != nil {
		return fmt.Errorf("click Register: %w", err)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(20*time.Second)); err != nil {
		return err
	}
	return openRegisteredApp(ctx, env, outDir)
}

func markRegistrationDocsViewport(ctx context.Context) error {
	const script = `(() => {
	  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
	  const register = [...document.querySelectorAll('*')]
	    .filter(el => visible(el) && (el.textContent || el.value || '').trim() === 'Register')
	    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
	  if (!register) return false;
	  const bottom = Math.min(document.documentElement.clientHeight,
	    register.getBoundingClientRect().bottom + 28);
	  const crop = document.createElement('div');
	  crop.dataset.emisarDocsEntraRegistration = 'true';
	  Object.assign(crop.style, {
	    position: 'fixed', left: '0', top: '42px', width: '1440px',
	    height: Math.max(700, bottom - 42) + 'px',
	    pointerEvents: 'none', zIndex: '2147483647'
	  });
  document.body.appendChild(crop);
  return true;
})()`
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return fmt.Errorf("could not isolate the Entra registration blade")
	}
	return nil
}

// highlightRegistrationGroup rings the complete redirect-URI unit: heading,
// explanation, platform, and URL. An outline applied to the heading's own node
// disappeared underneath the two inputs and looked broken in the published shot.
func highlightRegistrationGroup(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heading = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === 'Redirect URI (optional)')
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  const uri = [...document.querySelectorAll('input')]
    .filter(visible)
    .find(el => (el.value || '').includes('/sign_in/sso/callback'));
  if (!heading || !uri) return false;
  let node = heading;
  for (let up = 0; up < 8 && node; up++, node = node.parentElement) {
    const box = node.getBoundingClientRect();
    if (node.contains(uri) && box.width >= 600 && box.height >= 80 && box.height <= 180) {
      node.scrollIntoView({block: 'center'});
      const boxes = [node.getBoundingClientRect(), uri.getBoundingClientRect()];
      const current = {
        left: Math.min(...boxes.map(box => box.left)),
        top: Math.min(...boxes.map(box => box.top)),
        right: Math.max(...boxes.map(box => box.right)),
        bottom: Math.max(...boxes.map(box => box.bottom))
      };
      current.width = current.right - current.left;
      current.height = current.bottom - current.top;
      // At this fixed capture viewport Entra paints the heading and platform
      // selector 105px left of the CSS box it reports for their group.
      const paintedLeftOverflow = 105;
      const ring = document.createElement('div');
      Object.assign(ring.style, {
        position: 'fixed',
        left: (current.left - paintedLeftOverflow - 8) + 'px',
        top: (current.top - 8) + 'px',
        width: (current.width + paintedLeftOverflow + 16) + 'px',
        height: (current.height + 16) + 'px',
        border: '3px solid #10b981',
        borderRadius: '8px',
        boxSizing: 'border-box',
        pointerEvents: 'none',
        zIndex: '2147483647'
      });
      document.body.appendChild(ring);
      return true;
    }
  }
  return false;
})()`
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return errors.New("could not outline the complete Entra redirect URI group")
	}
	return chromedp.Run(ctx, chromedp.Sleep(700*time.Millisecond))
}

// openRegisteredApp captures the saved app's overview.
func openRegisteredApp(ctx context.Context, env map[string]string, outDir string) error {
	dismissOverlays(ctx)

	// Reach the saved app by its OWN blade. The App registrations LIST never
	// renders — it comes up as a blank shell headless or headful — but a
	// per-app blade addressed by client id does.
	if env["ENTRA_CLIENT_ID"] == "" {
		return fmt.Errorf("ENTRA_CLIENT_ID is empty — register the app first")
	}
	if err := openService(ctx, "App registrations", "Display name"); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "en-05-overview-failed")
		return err
	}
	if err := clickTextAtCentre(ctx, "emisar"); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "en-05-app-not-listed")
		return fmt.Errorf("open the emisar app: %w", err)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(15*time.Second)); err != nil {
		return err
	}
	dismissOverlays(ctx)
	if err := waitForText(ctx, "Application (client) ID", 90*time.Second); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "en-05-overview-failed")
		return fmt.Errorf("app overview never rendered: %w", err)
	}
	_ = highlight(ctx, "Application (client) ID")
	return idpcapture.Screenshot(ctx, outDir, "en-05-app-overview")
}

// openService reaches a portal service from the home page's Azure services tiles.
// Deep links are useless here — a cold hash URL lands on home, and assigning
// location.hash afterwards does not route because the portal owns its router —
// but the home tiles are plain clickable elements that do.
func openService(ctx context.Context, tile, expect string) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://portal.azure.com/"),
		chromedp.Sleep(18*time.Second),
	); err != nil {
		return err
	}
	dismissOverlays(ctx)

	// Clicking the tile only focuses it, and Enter does not activate it either. The
	// tile IS an anchor though, so take the portal's OWN href and load it as a full
	// navigation — a route the portal generated routes correctly where one I built
	// by hand does not.
	href, err := hrefOfTile(ctx, tile)
	if err != nil {
		_ = dumpOptions(ctx)
		return err
	}
	fmt.Printf("  %s -> %s\n", tile, href)
	if err := chromedp.Run(ctx,
		chromedp.Navigate(href),
		chromedp.Sleep(25*time.Second),
	); err != nil {
		return err
	}
	dismissOverlays(ctx)
	return waitForText(ctx, expect, 90*time.Second)
}

// dismissOverlays closes the NPS survey and teaching callouts the portal throws
// up unpredictably. They cover the very panel a step is trying to show, and they
// appear on no fixed schedule, so every capture point clears them first.
func dismissOverlays(ctx context.Context) {
	const script = `(() => {
  let closed = 0;
  for (const el of document.querySelectorAll('button,[role=button],a')) {
    const label = ((el.getAttribute('aria-label') || '') + ' ' + (el.title || '')).toLowerCase();
    if (/close|dismiss|not now|maybe later|no thanks/.test(label)) {
      const box = el.getBoundingClientRect();
      if (box.width > 0 && box.height > 0) { el.click(); closed++; }
    }
  }
  return closed;
})()`
	var closed int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &closed)); err == nil && closed > 0 {
		fmt.Printf("  dismissed %d overlay(s)\n", closed)
		_ = chromedp.Run(ctx, chromedp.Sleep(2*time.Second))
	}
}

// selectPlatform picks a Redirect URI platform. Azure's combo box listens for
// POINTER events, so a synthetic element.click() opens nothing and the option
// list never enters the DOM — four variants of that failed. Dispatch a real
// mouse click at the control's centre instead.
func selectPlatform(ctx context.Context, option string) error {
	// Anchor on the control's OWN text. Selecting by [role=combobox] alone hits the
	// portal's top-bar search, which is also a combobox and comes first in the DOM —
	// the run then reported "Searching all subscriptions" instead of a platform list.
	if err := clickTextAtCentre(ctx, "Select a platform"); err != nil {
		return fmt.Errorf("open platform dropdown: %w", err)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}

	// The option needs a real mouse click too — same pointer-event handling as the
	// combo that opens it.
	if err := clickTextAtCentre(ctx, option); err != nil {
		_ = dumpOptions(ctx)
		return fmt.Errorf("pick %q: %w", option, err)
	}
	// clickText returning true only means SOMETHING matched the label — it does not
	// mean the combo took the value. It reported success while the form still read
	// "Platform is required", which silently broke every later step. Verify against
	// the rendered form, and fail loudly when the value did not stick.
	if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	var body string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
		return err
	}
	if strings.Contains(body, "Platform is required") || strings.Contains(body, "Select a platform") {
		return fmt.Errorf("platform %q did not stick — the form still demands one", option)
	}
	fmt.Printf("  platform %q selected\n", option)
	return nil
}

// clickTextAtCentre dispatches a real mouse click at the middle of the smallest
// visible element carrying the given text. Needed wherever a widget ignores a
// synthetic click, and precise enough not to hit a same-role element elsewhere.
func clickTextAtCentre(ctx context.Context, label string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q);
  if (!matches.length) return null;
  matches.sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  const el = matches[0];
  el.scrollIntoView({block: 'center'});
  const r = el.getBoundingClientRect();
  return JSON.stringify({x: r.left + r.width / 2, y: r.top + r.height / 2});
})()`, label)

	var raw string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &raw)); err != nil {
		return err
	}
	if raw == "" {
		return fmt.Errorf("nothing visible matching %q", label)
	}
	var point struct{ X, Y float64 }
	if err := json.Unmarshal([]byte(raw), &point); err != nil {
		return err
	}
	return chromedp.Run(ctx, chromedp.MouseClickXY(point.X, point.Y))
}

func highlight(ctx context.Context, label string) error {
	return capture.Highlight(ctx, label, 700*time.Millisecond)
}

// fillField types into the input whose label, placeholder or aria-label matches.
// The Entra admin center is React-driven, so an assigned .value is ignored —
// focus the element and send real key events.
func fillField(ctx context.Context, hint, value string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hint = %q.toLowerCase();
  const field = [...document.querySelectorAll('input,textarea')].filter(visible).find(el =>
    (el.getAttribute('aria-label') || '').toLowerCase().includes(hint) ||
    (el.placeholder || '').toLowerCase().includes(hint) ||
    (el.labels && [...el.labels].some(l => l.textContent.toLowerCase().includes(hint))));
  if (!field) return false;
  field.scrollIntoView({block: 'center'});
  field.focus();
  return true;
})()`, hint)
	var focused bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &focused)); err != nil {
		return err
	}
	if !focused {
		return fmt.Errorf("no field matching %q", hint)
	}
	return chromedp.Run(ctx, chromedp.KeyEvent(value), chromedp.Sleep(time.Second))
}

// dumpOptions lists the short visible labels on screen, so a missed dropdown
// option is diagnosed from the real menu rather than another guess at its text.
func dumpOptions(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const seen = new Set();
  for (const el of document.querySelectorAll('li,[role=option],[role=menuitem],button,a,span,div')) {
    if (!visible(el)) continue;
    if (el.getElementsByTagName('*').length > 2) continue;
    const t = (el.textContent || '').trim();
    if (t && t.length < 60) seen.add(t);
  }
  return [...seen].join(' | ');
})()`
	var listing string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &listing)); err != nil {
		return err
	}
	fmt.Println("--- visible labels ---")
	fmt.Println(listing)
	return nil
}

// hrefOfTile returns the href of the anchor carrying the given tile label.
func hrefOfTile(ctx context.Context, label string) (string, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const norm = t => (t || '').replace(/\s+/g, ' ').trim();
  const a = [...document.querySelectorAll('a[href]')].filter(visible)
    .find(el => norm(el.textContent) === %q);
  return a ? a.href : '';
})()`, label)
	var href string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &href)); err != nil {
		return "", err
	}
	if href == "" {
		return "", fmt.Errorf("no anchor for tile %q", label)
	}
	return href, nil
}
