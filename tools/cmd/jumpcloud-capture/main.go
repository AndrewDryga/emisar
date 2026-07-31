// Command jumpcloud-capture drives a live JumpCloud admin console and
// photographs the OIDC + SCIM setup path, the JumpCloud twin of okta-capture.
//
// Auth is plain form login: JumpCloud's /api/authenticate is CSRF-protected, so
// typing into the real form is both simpler and more faithful than minting a
// token out of band.
//
// Reads JUMPCLOUD_* from portal/.agent/secrets/jumpcloud-trial.env (gitignored).
// DEV ONLY, and it lives in the never-shipped tools module.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	var secretsPath, outDir string
	var headless, listApps, cleanupApps bool
	flag.StringVar(&secretsPath, "secrets", "portal/.agent/secrets/jumpcloud-trial.env", "creds env file")
	flag.StringVar(&outDir, "out", "", "directory for captured PNGs")
	flag.BoolVar(&headless, "headless", true, "run Chrome headless")
	// Every full run creates an application. This lists what is there so a cleanup
	// can be decided from facts rather than a guess about which rows are mine.
	flag.BoolVar(&listApps, "list-apps", false, "print the configured applications and exit")
	flag.BoolVar(&cleanupApps, "cleanup-apps", false, "delete the emisar apps a capture run left behind, and exit")
	flag.Parse()

	if outDir == "" {
		fmt.Fprintln(os.Stderr, "-out is required")
		os.Exit(1)
	}
	env, err := readEnv(secretsPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "jumpcloud-capture:", err)
		os.Exit(1)
	}
	if err := run(env, outDir, headless, listApps, cleanupApps); err != nil {
		fmt.Fprintln(os.Stderr, "jumpcloud-capture:", err)
		os.Exit(1)
	}
}

func readEnv(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	env := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if key, value, found := strings.Cut(line, "="); found {
			env[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	// The process environment wins. The tunnel URL and SCIM token change on every
	// run — they belong to the moment, not in a credentials file that outlives it.
	for _, key := range []string{"EMISAR_PUBLIC_URL", "EMISAR_SCIM_TOKEN", "EMISAR_DOCS_HOST"} {
		if value := os.Getenv(key); value != "" {
			env[key] = value
		}
	}
	return env, scanner.Err()
}

// focusField puts the cursor in a field so chromedp.KeyEvent types with real key
// events — the console is React-driven and ignores assigned values.
func focusField(ctx context.Context, hint string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hint = %q.toLowerCase();
  const match = [...document.querySelectorAll('input')].filter(visible).find(el =>
    (el.name || '').toLowerCase().includes(hint) ||
    (el.id || '').toLowerCase().includes(hint) ||
    (el.type || '').toLowerCase() === hint ||
    (el.placeholder || '').toLowerCase().includes(hint) ||
    (el.getAttribute('aria-label') || '').toLowerCase().includes(hint));
  // Fall back to the visible CAPTION. Several inputs on these forms carry no
  // name, id, placeholder or aria-label at all — the words the operator reads are
  // a sibling node — so an attribute search finds nothing for a field that is
  // right there. Login URL is one, and missing it made Activate fail validation
  // silently.
  const byCaption = () => {
    const captions = [...document.querySelectorAll('label,span,div')]
      .filter(el => visible(el) && (el.textContent || '').trim().toLowerCase().replace(/\s*\*$/, '') === hint)
      .sort((a, b) => a.textContent.length - b.textContent.length);
    for (const caption of captions) {
      let node = caption;
      for (let up = 0; up < 5 && node; up++) {
        const input = node.querySelector('input:not([type=hidden])');
        if (input && visible(input)) return input;
        node = node.parentElement;
      }
    }
    return null;
  };
  const target = match || byCaption();
  if (!target) return false;
  target.scrollIntoView({block: 'center'});
  target.focus();
  target.select && target.select();
  return true;
})()`, hint)
	var focused bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &focused)); err != nil {
		return err
	}
	if !focused {
		return fmt.Errorf("no field matching %q", hint)
	}
	return nil
}

func clickText(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const target = [...document.querySelectorAll('a,button,input[type=submit],[role=button]')]
    .find(el => visible(el) && ((el.textContent || el.value || '').trim() === %q));
  if (!target) return false;
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// clickDeep clicks a control by exact label, walking OPEN SHADOW ROOTS as well as
// the light DOM. JumpCloud renders the app's sticky action bar — Activate, Test
// Connection — inside a web component, so a plain querySelectorAll finds nothing
// while the button sits in plain view on the screenshot.
func clickDeep(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  // Case-INSENSITIVE: a control's rendered capitals can come from CSS
  // text-transform, so the screenshot says "Activate" while the DOM says
  // "activate" and an exact match finds a button that is plainly on screen.
  const wanted = %q.toLowerCase();
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const found = [];
  const walk = root => {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) walk(el.shadowRoot);
      if (!visible(el)) continue;
      if ((el.textContent || '').trim().toLowerCase() !== wanted) continue;
      if (el.querySelector('*') && [...el.children].some(c => (c.textContent || '').trim().toLowerCase() === wanted)) continue;
      found.push(el);
    }
  };
  walk(document);
  if (!found.length) return false;
  const target = found[0].closest ? (found[0].closest('button,a,[role=button]') || found[0]) : found[0];
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// clickContaining clicks the smallest visible element whose text contains the
// label — list rows bundle status and column text alongside the name, so an
// exact match misses them.
func clickContaining(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('a,button,li,tr,td,div,span,[role=button]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  matches[0].scrollIntoView({block: 'center'});
  matches[0].click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// deidentifyHost rewrites the tunnel hostname to the product host for the
// screenshot only. The host is the one substitution our capture rule allows;
// never use it on a status, an outcome, or any value that carries meaning.
func deidentifyHost(ctx context.Context, from, to string) error {
	script := fmt.Sprintf(`(() => {
  const from = %q, to = %q;
  let changed = 0;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  for (const el of document.querySelectorAll('input')) {
    if (el.value && el.value.includes(from)) { setter.call(el, el.value.split(from).join(to)); changed++; }
  }
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.nodeValue && node.nodeValue.includes(from)) {
      node.nodeValue = node.nodeValue.split(from).join(to); changed++;
    }
  }
  return changed;
})()`, from, to)
	var changed int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &changed)); err != nil {
		return err
	}
	fmt.Printf("  de-identified host in %d place(s)\n", changed)
	return nil
}

func screenshot(ctx context.Context, outDir, name string) error {
	var buffer []byte
	if err := chromedp.Run(ctx, chromedp.FullScreenshot(&buffer, 90)); err != nil {
		return err
	}
	path := filepath.Join(outDir, name+".png")
	if err := os.WriteFile(path, buffer, 0o644); err != nil {
		return err
	}
	fmt.Println("  shot", name)
	return nil
}

func run(env map[string]string, outDir string, headless, listApps, cleanupApps bool) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	options := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", headless),
		chromedp.WindowSize(1440, 1200),
	)
	allocator, cancelAllocator := chromedp.NewExecAllocator(context.Background(), options...)
	defer cancelAllocator()
	ctx, cancel := chromedp.NewContext(allocator)
	defer cancel()
	// The whole run: sign in, create the app, activate SSO, configure provisioning,
	// then WAIT for JumpCloud to report provisioning active. Four minutes covered
	// the flow before that last wait existed, and then expired inside it.
	ctx, cancelTimeout := context.WithTimeout(ctx, 12*time.Minute)
	defer cancelTimeout()

	if err := chromedp.Run(ctx,
		chromedp.Navigate(env["JUMPCLOUD_CONSOLE_URL"]+"/login"),
		chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}

	// The login page carries Admin Login / User Login tabs and defaults to the
	// user directory; submitting there fails with "Are you trying to log in as an
	// Administrator?". Select the admin tab before typing anything.
	if clicked, err := clickText(ctx, "Admin Login"); err != nil {
		return err
	} else if clicked {
		if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
			return err
		}
	}
	if err := focusField(ctx, "email"); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent(env["JUMPCLOUD_ADMIN_USER"])); err != nil {
		return err
	}
	// The console asks for the email first and only reveals the password field
	// after it advances, so try the password now and, failing that, advance and
	// look again.
	if err := focusField(ctx, "password"); err != nil {
		for _, label := range []string{"Continue", "Next", "Log In", "Sign In"} {
			if clicked, clickErr := clickText(ctx, label); clickErr != nil {
				return clickErr
			} else if clicked {
				break
			}
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
			return err
		}
		if err := screenshot(ctx, outDir, "jc-00-login-step2"); err != nil {
			return err
		}
		if err := focusField(ctx, "password"); err != nil {
			return err
		}
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent(env["JUMPCLOUD_ADMIN_PASSWORD"])); err != nil {
		return err
	}
	// The password step's submit is "Admin Login" — the same string as the tab on
	// the email step, which is why it has to be tried here explicitly.
	submitted := false
	for _, label := range []string{"Admin Login", "Login", "Log In", "Sign In"} {
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		if clicked {
			submitted = true
			break
		}
	}
	if !submitted {
		return fmt.Errorf("no submit button on the password step")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(12*time.Second)); err != nil {
		return err
	}

	var location, text string
	if err := chromedp.Run(ctx,
		chromedp.Location(&location),
		chromedp.Evaluate(`document.body.innerText.replace(/\n{2,}/g,"\n").slice(0,500)`, &text)); err != nil {
		return err
	}
	fmt.Printf("landed on: %s\n--- page ---\n%s\n---\n", location, text)
	if err := screenshot(ctx, outDir, "jc-01-after-login"); err != nil {
		return err
	}
	if listApps {
		return printApplications(ctx, env, outDir)
	}
	if cleanupApps {
		return cleanupCaptureApplications(ctx, env["JUMPCLOUD_CONSOLE_URL"], outDir)
	}
	return ssoApplicationsFlow(ctx, env, outDir)
}

// openApplicationList routes straight to the configured applications. Clicking
// the left nav did not get there — Access opens a section, not that list — and
// the capture flow already navigates by URL for the same reason.
func openApplicationList(ctx context.Context, consoleURL string) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate(consoleURL+"/#/applications"),
		chromedp.Sleep(12*time.Second)); err != nil {
		return err
	}
	return nil
}

// cleanupCaptureApplications removes the applications a capture run leaves in the
// tenant. Each full run creates one, and chasing a form through several attempts
// leaves several.
//
// The filter is deliberately narrow: a row is only touched when its label is
// exactly "emisar" AND it advertises neither provisioning nor a certificate —
// which is what an abandoned half-configured run looks like. The certified app
// carries both and is never selected.
func cleanupCaptureApplications(ctx context.Context, consoleURL, outDir string) error {
	if err := openApplicationList(ctx, consoleURL); err != nil {
		return err
	}

	// By GEOMETRY. The list is a virtualized div grid: the checkboxes are real, but
	// a row's label is not in their ancestors, so climbing found nothing and the
	// cleanup reported a clean tenant over visible litter. Pair each checkbox with
	// the text sitting on its own line instead.
	const selectAbandoned = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const boxes = [...document.querySelectorAll('input[type=checkbox]')].filter(visible);
  const leaves = [...document.querySelectorAll('*')].filter(el =>
    visible(el) && !el.querySelector('*') && (el.textContent || '').trim());
  const rowText = box => {
    const r = box.getBoundingClientRect();
    const mid = r.top + r.height / 2;
    return leaves
      .filter(el => { const b = el.getBoundingClientRect(); return b.top <= mid && b.bottom >= mid; })
      .map(el => (el.textContent || '').trim())
      .join(' | ');
  };
  const picked = [];
  for (const box of boxes) {
    if (box.checked) continue;
    const text = rowText(box);
    if (!/\bemisar\b/.test(text)) continue;
    // The CERTIFICATE marks a keeper, not the provisioning badge. Sparing anything
    // that advertised provisioning left every run's ACTIVATED app behind, which is
    // why the count kept climbing however often this was run.
    if (/Expires/.test(text)) continue;
    box.click();
    picked.push(text.slice(0, 70));
  }
  return picked.join('\n');
})()`
	var picked string
	if err := chromedp.Run(ctx, chromedp.Evaluate(selectAbandoned, &picked)); err != nil {
		return err
	}
	if strings.TrimSpace(picked) == "" {
		// Say WHY nothing matched. "Nothing to clean up" on a tenant that visibly
		// has litter is the same false all-clear this cleanup already reported once.
		const probe = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const boxes = [...document.querySelectorAll('input[type=checkbox]')].filter(visible);
  const rows = [...document.querySelectorAll('[role=row]')].filter(visible);
  return 'checkboxes=' + boxes.length + ' roleRows=' + rows.length +
    ' sample=' + rows.slice(0, 3).map(r => (r.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 50)).join(' // ');
})()`
		var why string
		_ = chromedp.Run(ctx, chromedp.Evaluate(probe, &why))
		fmt.Printf("  nothing selected — %s\n", why)
		return screenshot(ctx, outDir, "jc-cleanup-nothing-selected")
	}
	fmt.Println("--- selected for deletion ---")
	fmt.Println(picked)
	if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-cleanup-selected"); err != nil {
		return err
	}
	if clicked, err := clickDeep(ctx, "Delete"); err != nil {
		return err
	} else if !clicked {
		return errors.New("no Delete control on the applications list")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(4*time.Second)); err != nil {
		return err
	}
	// Their confirmation asks for the COUNT, not the word "delete": "Enter the
	// number of applications to be deleted", and its button stays disabled until
	// the number matches. Typing a word left it disabled and the run reported a
	// deletion that never happened.
	count := len(strings.Split(strings.TrimSpace(picked), "\n"))

	typed := fmt.Sprintf(`(() => {
  const wanted = %q;
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  // Inside the DIALOG. Taking the last input on the page grabbed a control behind
  // it, so the confirmation field stayed empty and its button stayed disabled —
  // the run then reported a deletion the UI had refused.
  const prompt = [...document.querySelectorAll('*')].find(el =>
    visible(el) && /Enter the number of applications/.test(el.textContent || '') && !el.querySelector('*'));
  const dialog = prompt ? prompt.closest('div[role=dialog]') || prompt.parentElement.parentElement : null;
  const input = dialog
    ? [...dialog.querySelectorAll('input')].find(el => visible(el))
    : null;
  if (!input) return false;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, wanted);
  input.dispatchEvent(new Event('input', {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
})()`, strconv.Itoa(count))

	var confirmed bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(typed, &confirmed)); err != nil {
		return err
	}
	if !confirmed {
		return errors.New("the delete dialog has no field to confirm the count in")
	}
	fmt.Printf("  confirming deletion of %d\n", count)
	if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	// The dialog's BUTTON, not its heading — both read "Delete Applications", and
	// clicking the heading did nothing while the run reported it confirmed.
	const confirmButton = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const button = [...document.querySelectorAll('button')]
    .find(el => visible(el) && !el.disabled && /^Delete Applications?$/.test((el.textContent || '').trim()));
  if (!button) return false;
  button.click();
  return true;
})()`
	var pressed bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(confirmButton, &pressed)); err != nil {
		return err
	}
	if !pressed {
		return errors.New("the delete dialog's confirm button is absent or still disabled")
	}
	fmt.Println("  confirmed")
	if err := chromedp.Run(ctx, chromedp.Sleep(10*time.Second)); err != nil {
		return err
	}
	return screenshot(ctx, outDir, "jc-cleanup-done")
}

// printApplications walks to the configured-application list and prints each row,
// so the litter a repeated capture run leaves can be identified before anything
// is deleted.
func printApplications(ctx context.Context, env map[string]string, outDir string) error {
	if err := openApplicationList(ctx, env["JUMPCLOUD_CONSOLE_URL"]); err != nil {
		return err
	}
	const rows = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return [...document.querySelectorAll('tr')]
    .filter(visible)
    .map(tr => [...tr.children].map(td => (td.textContent || '').trim()).filter(Boolean).join(' | '))
    .filter(Boolean)
    .join('\n');
})()`
	var listing string
	if err := chromedp.Run(ctx, chromedp.Evaluate(rows, &listing)); err != nil {
		return err
	}
	fmt.Println("--- configured applications ---")
	fmt.Println(listing)
	return screenshot(ctx, outDir, "jc-applications")
}

// ssoApplicationsFlow opens the SSO application catalog and reports what the
// "custom" options actually are. This is the step that settles, by observation,
// whether JumpCloud lets one app carry both OIDC sign-in and SCIM provisioning —
// their docs omit OIDC from the custom-SCIM bases, and our shipped copy was
// corrected on that basis alone.
func ssoApplicationsFlow(ctx context.Context, env map[string]string, outDir string) error {
	// Hash deep-links don't route this SPA (#/sso/applications leaves you on the
	// onboarding page), so walk the left nav: Access → SSO Applications.
	// The nav is intermittent (JumpCloud had an incident banner up throughout), so
	// retry the two-step walk rather than failing the run on one missed click.
	// Resuming against an app that already exists: go straight to it. Re-running
	// the wizard makes a DUPLICATE app, which happened once already.
	if env["JUMPCLOUD_APP_ID"] != "" {
		// Only /#/applications routes; a per-app deep link lands on Home, and then
		// a tab-name click hits the LEFT NAV item of the same name instead. Open
		// the app from the list.
		if err := chromedp.Run(ctx,
			chromedp.Navigate(env["JUMPCLOUD_CONSOLE_URL"]+"/#/applications"),
			chromedp.Sleep(10*time.Second)); err != nil {
			return err
		}
		// The row carries status and column text alongside the label, so an exact
		// match misses it.
		if clicked, err := clickContaining(ctx, "emisar"); err != nil {
			return err
		} else if !clicked {
			_ = screenshot(ctx, outDir, "jc-09-app-not-listed")
			return fmt.Errorf("emisar not in the applications list")
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(9*time.Second)); err != nil {
			return err
		}
		if err := screenshot(ctx, outDir, "jc-09-app-detail"); err != nil {
			return err
		}
		return provisioningTabFlow(ctx, env, outDir)
	}

	reached := false
	// URL first: the nav is a flyout whose items aren't always clickable, and it
	// failed 3/3 on some runs. Try the SPA routes, then fall back to the menu.
	for _, route := range []string{"/#/applications", "/#/sso", "/#/sso/applications"} {
		if err := chromedp.Run(ctx,
			chromedp.Navigate(env["JUMPCLOUD_CONSOLE_URL"]+route),
			chromedp.Sleep(8*time.Second)); err != nil {
			return err
		}
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, "Configured Applications") {
			fmt.Printf("  reached applications via %s\n", route)
			reached = true
			break
		}
	}
	for attempt := 1; attempt <= 3 && !reached; attempt++ {
		if _, err := clickText(ctx, "Access"); err != nil {
			return err
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(5*time.Second)); err != nil {
			return err
		}
		for _, label := range []string{"SSO Applications", "Applications"} {
			clicked, err := clickText(ctx, label)
			if err != nil {
				return err
			}
			if clicked {
				fmt.Printf("  clicked %q (attempt %d)\n", label, attempt)
				break
			}
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(10*time.Second)); err != nil {
			return err
		}
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		reached = strings.Contains(body, "Configured Applications")
	}
	if !reached {
		_ = screenshot(ctx, outDir, "jc-02-nav-failed")
		return fmt.Errorf("could not reach SSO Applications after 3 attempts")
	}
	if err := highlight(ctx, "Add New Application"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-02-sso-applications"); err != nil {
		return err
	}

	for _, label := range []string{"Add New Application", "+ Add New Application", "Get Started"} {
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		if clicked {
			fmt.Printf("  clicked %q\n", label)
			break
		}
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}
	if err := highlight(ctx, "Custom Application"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-03-add-application"); err != nil {
		return err
	}

	// Do NOT type into a "search" field here: the console's global search sits in
	// the top bar and matches that hint first, opening a modal OVER the wizard.
	// The wizard offers the custom integration directly.
	picked := false
	for _, label := range []string{"Custom Application", "custom integration"} {
		clicked, err := clickInDialog(ctx, label)
		if err != nil {
			return err
		}
		if clicked {
			fmt.Printf("  picked %q\n", label)
			picked = true
			break
		}
	}
	if !picked {
		_ = screenshot(ctx, outDir, "jc-04-no-custom-tile")
		_ = describePage(ctx)
		return fmt.Errorf("no custom-integration option on the wizard's first step")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(4*time.Second)); err != nil {
		return err
	}
	if clicked, err := clickText(ctx, "Next"); err != nil {
		return err
	} else if clicked {
		fmt.Println(`  clicked "Next"`)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}
	// Step 2 "Select Options" — the screen that shows whether SSO and provisioning
	// can live on ONE app, which is the claim this certification exists to settle.
	if err := highlightControl(ctx, "Manage Single Sign-On (SSO)"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-05-select-options"); err != nil {
		return err
	}

	// The decisive test: ask for BOTH login and outbound provisioning on one app,
	// then pick OIDC. JumpCloud's docs say OIDC cannot carry provisioning; this is
	// where the console either agrees or refutes them.
	for _, section := range []string{"Manage Single Sign-On (SSO)", "Export users to this app"} {
		ticked, err := tickInSection(ctx, section)
		if err != nil {
			return err
		}
		fmt.Printf("  tick %q: %t\n", section, ticked)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	// Ticking SSO reveals a SAML/OIDC radio pair that defaults to SAML. Choosing
	// OIDC here is the actual test: does JumpCloud still allow provisioning?
	oidc, err := clickRadio(ctx, "Configure SSO with OIDC")
	if err != nil {
		return err
	}
	fmt.Printf("  radio \"Configure SSO with OIDC\": %t\n", oidc)
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	if err := highlightControl(ctx, "Configure SSO with OIDC"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-06-options-chosen"); err != nil {
		return err
	}
	if err := describePage(ctx); err != nil {
		return err
	}
	if clicked, err := clickText(ctx, "Next"); err != nil {
		return err
	} else if !clicked {
		return fmt.Errorf("next disabled after choosing SSO + Export users")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}
	// Step 3 is general info. Fill the field BEFORE shooting: a walkthrough frame
	// showing an empty Display Label teaches nothing, and shipping one is exactly
	// what drew "you again did not select right options on the screenshots".
	if err := focusField(ctx, "label"); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent("emisar"), chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	if err := highlight(ctx, "Display Label"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-07-general-info"); err != nil {
		return err
	}
	for _, label := range []string{"Next", "Save Application"} {
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		if clicked {
			fmt.Printf("  clicked %q\n", label)
			if err := chromedp.Run(ctx, chromedp.Sleep(6*time.Second)); err != nil {
				return err
			}
		}
	}
	if err := highlight(ctx, "Enabled Features"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-08-after-save"); err != nil {
		return err
	}
	// Past Review is where the OIDC redirect URI and the client credentials live —
	// the screen an operator cannot finish SSO without. The wizard's Review step
	// only summarises, so a guide that stops here leaves the reader stranded.
	if clicked, err := clickText(ctx, "Configure Application"); err != nil {
		return err
	} else if !clicked {
		return fmt.Errorf("no Configure Application button on the review step")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(10*time.Second)); err != nil {
		return err
	}
	if err := describePage(ctx); err != nil {
		return err
	}
	// Fill the redirect URI before shooting, for the same reason step 3 is filled:
	// an empty field teaches nothing.
	if err := focusField(ctx, "Redirect"); err == nil {
		_ = chromedp.Run(ctx,
			chromedp.KeyEvent("https://emisar.dev/sign_in/sso/callback"),
			chromedp.Sleep(2*time.Second))
	}
	// Login URL is required and empty on a fresh OIDC app. Leaving it blank made
	// Activate look like it worked while the form silently failed validation, so
	// the SSO config stayed unsaved and the Provisioning tab kept raising the
	// unsaved-changes dialog over the fields the run needed.
	if err := focusField(ctx, "Login URL"); err == nil {
		_ = chromedp.Run(ctx,
			chromedp.KeyEvent("https://emisar.dev/sign_in"),
			chromedp.Sleep(2*time.Second))
	}
	if err := highlight(ctx, "Redirect URIs"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-09-oidc-config"); err != nil {
		return err
	}
	if err := describeFields(ctx); err != nil {
		return err
	}

	// Activate the SSO config BEFORE leaving this tab. Switching to Provisioning
	// with the redirect URI unsaved raises JumpCloud's "Unsaved Changes" dialog,
	// which sits over the tab so its fields never render — the run then failed
	// looking for Base URL on a page it had never actually reached.
	// Remember where the app lives BEFORE activating. Activation ends on the
	// applications LIST, not the app, and the run used to assume it was still on
	// the app — then hunted for a Provisioning tab on a table of rows.
	var appURL string
	if err := chromedp.Run(ctx, chromedp.Location(&appURL)); err != nil {
		return err
	}

	clicked, err := clickText(ctx, "Activate")
	if err != nil {
		return err
	}
	if !clicked {
		// The footer's Activate is not one of the tags clickText scans, so fall back
		// to the containing match before giving up on a control that is right there.
		if clicked, err = clickDeep(ctx, "Activate"); err != nil {
			return err
		}
	}
	if !clicked {
		if clicked, err = clickContaining(ctx, "Activate"); err != nil {
			return err
		}
	}
	if !clicked {
		_ = screenshot(ctx, outDir, "jc-09-no-activate")
		// Say what WAS clickable, walking shadow roots — "not found" alone cannot
		// tell a renamed control from a page that had already moved on.
		const labels = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const out = [];
  const walk = root => {
    for (const el of root.querySelectorAll('button,a,[role=button],input[type=submit]')) {
      if (el.shadowRoot) walk(el.shadowRoot);
      if (!visible(el)) continue;
      const text = (el.textContent || el.value || '').trim();
      if (text && text.length < 40) out.push(text);
    }
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot);
  };
  walk(document);
  return [...new Set(out)].slice(0, 40).join(' | ');
})()`
		var visible string
		_ = chromedp.Run(ctx, chromedp.Evaluate(labels, &visible))
		return fmt.Errorf("no Activate control on the OIDC configuration; clickable: %s", visible)
	}
	fmt.Println("  activated the SSO configuration")
	if err := chromedp.Run(ctx, chromedp.Sleep(12*time.Second)); err != nil {
		return err
	}
	// Activation puts up an "Application Activated" dialog carrying the client id
	// and the client SECRET, which JumpCloud shows once. Dismiss it before doing
	// anything else: it covers the tabs — every earlier attempt to open
	// Provisioning was clicking through this — and photographing it would write a
	// live credential to disk.
	dismissed, err := clickDeep(ctx, "Got It")
	if err != nil {
		return err
	}
	if !dismissed {
		return errors.New("the activation dialog has no Got It to dismiss")
	}
	fmt.Println("  dismissed the activation dialog")
	if err := chromedp.Run(ctx, chromedp.Sleep(4*time.Second)); err != nil {
		return err
	}
	// One implementation of "get back to the app we just made", shared with the
	// retry below — there were briefly two, reopening in sequence and undoing each
	// other. Activation ends on the applications list, and this run's app is the
	// only "emisar" there without a certificate. (Run -cleanup-apps first;
	// leftovers from earlier attempts look identical.)
	_ = appURL

	if err := reopenSavedApp(ctx, env, outDir); err != nil {
		return err
	}

	// Provisioning wiring needs emisar reachable from JumpCloud's servers, which a
	// screenshot run has no tunnel for.
	if env["EMISAR_PUBLIC_URL"] == "" {
		fmt.Println("  EMISAR_PUBLIC_URL unset — stopping, skipping provisioning")
		return nil
	}
	return provisioningFlow(ctx, env, outDir)
}

// provisioningFlow wires the saved app's Provisioning tab at emisar's SCIM
// endpoint and activates it. Activation is what makes JumpCloud actually push,
// which is the only way to observe what it really sends as externalId — their
// docs describe a fallback, not a guarantee.
func provisioningFlow(ctx context.Context, env map[string]string, outDir string) error {
	// Saving leaves the browser ON the new app, with its tabs already showing, so
	// look before navigating: going back to the list to re-find the app by name
	// failed on a tenant where the list had not caught up with the save yet.
	var body string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
		return err
	}
	// The app's own tab strip is the tell. Requiring "General Info" as well made
	// this miss once the activation dialog had been dismissed and the page
	// re-rendered, sending the run back to a list it did not need.
	if strings.Contains(body, "Provisioning") && strings.Contains(body, "User Groups") {
		fmt.Println("  already on the saved app")
		return provisioningTabFlow(ctx, env, outDir)
	}
	if clicked, err := clickText(ctx, "emisar"); err != nil {
		return err
	} else if !clicked {
		return fmt.Errorf("saved app not listed")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}
	return provisioningTabFlow(ctx, env, outDir)
}

// reopenSavedApp returns to the app this run created and opens its Provisioning
// tab. Split out because it is needed twice: once after activation drops us on
// the applications list, and again whenever the provisioning form has not
// painted yet.
func reopenSavedApp(ctx context.Context, env map[string]string, outDir string) error {
	if err := openApplicationList(ctx, env["JUMPCLOUD_CONSOLE_URL"]); err != nil {
		return err
	}

	const openFreshApp = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const boxes = [...document.querySelectorAll('input[type=checkbox]')].filter(visible);
  const leaves = [...document.querySelectorAll('*')].filter(el =>
    visible(el) && !el.querySelector('*') && (el.textContent || '').trim());
  for (const box of boxes) {
    const r = box.getBoundingClientRect();
    const mid = r.top + r.height / 2;
    const row = leaves.filter(el => {
      const b = el.getBoundingClientRect();
      return b.top <= mid && b.bottom >= mid;
    });
    const text = row.map(el => (el.textContent || '').trim()).join(' | ');
    if (!/\bemisar\b/.test(text)) continue;
    if (/Expires/.test(text)) continue;
    const label = row.find(el => (el.textContent || '').trim() === 'emisar');
    if (!label) continue;
    const labelBox = label.getBoundingClientRect();
    return JSON.stringify({x: Math.round(labelBox.left + labelBox.width / 2), y: Math.round(labelBox.top + labelBox.height / 2), text: text.slice(0, 60)});
  }
  return '';
})()`
	var found string
	if err := chromedp.Run(ctx, chromedp.Evaluate(openFreshApp, &found)); err != nil {
		return err
	}
	if found == "" {
		_ = screenshot(ctx, outDir, "jc-09-cannot-find-fresh-app")
		return errors.New("the app just created is not identifiable in the list — run -cleanup-apps first")
	}

	var at struct {
		X, Y float64
		Text string
	}
	if err := json.Unmarshal([]byte(found), &at); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.MouseClickXY(at.X, at.Y), chromedp.Sleep(14*time.Second)); err != nil {
		return err
	}
	fmt.Printf("  reopened the saved app (%s)\n", at.Text)

	return openProvisioningTab(ctx)
}

// openProvisioningTab clicks the app's own Provisioning tab, scoped to the tab
// strip — "Provisioning" also names a badge in the applications list, and
// matching that navigated back to the list while reporting success.
func openProvisioningTab(ctx context.Context) error {
	const openTab = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  // Already there? Clicking the tab again toggles it back off, which is exactly
  // what happened when two callers each opened it.
  if (/Authentication method|SCIM Version|Custom Provisioning/.test(document.body.innerText)) {
    return 'already open';
  }
  const wanted = ['Provisioning', 'Identity Management'];
  for (const el of document.querySelectorAll('*')) {
    if (!visible(el)) continue;
    const text = (el.textContent || '').trim();
    if (!wanted.includes(text)) continue;
    if (el.querySelector('*')) continue;
    const strip = el.closest('ul,nav,div');
    if (!strip) continue;
    const siblings = (strip.parentElement || strip).textContent || '';
    if (!/General Info/.test(siblings) || !/User Groups/.test(siblings)) continue;
    el.click();
    return text;
  }
  return '';
})()`
	var opened string
	if err := chromedp.Run(ctx, chromedp.Evaluate(openTab, &opened)); err != nil {
		return err
	}
	if opened != "" {
		fmt.Printf("  opened %q tab\n", opened)
	}

	return chromedp.Run(ctx, chromedp.Sleep(8*time.Second))
}

// provisioningTabFlow opens the app's provisioning tab and reports its fields.
func provisioningTabFlow(ctx context.Context, env map[string]string, outDir string) error {
	// Their own docs use both names for this tab; try each. clickDeep first,
	// because the tab is not an anchor or a button — clickText missed it and the
	// run then matched "Identity Management" in the LEFT NAV, which is a different
	// product area entirely, and reported success for opening the wrong page.
	// The tab is opened by reopenSavedApp, which is also what the retry below
	// calls — opening it a second time here toggled back off.
	if err := openProvisioningTab(ctx); err != nil {
		return err
	}
	opened := "Provisioning"
	if opened == "" {
		_ = screenshot(ctx, outDir, "jc-09-no-provisioning-tab")
		_ = describePage(ctx)
		return fmt.Errorf("no Provisioning / Identity Management tab on the saved app")
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(6*time.Second)); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-09-provisioning-tab"); err != nil {
		return err
	}

	// Bearer token is emisar's shape; the alternative is an API-key header. It is a
	// TOGGLE PAIR, not a radio group — clickRadio found nothing for it, and there
	// is no "SCIM API" control at all (the SCIM version is fixed text). Both were
	// reported as a benign false and the run carried on into a form it had not
	// configured.
	// Retry, because reopening the app in a virtualised list is genuinely
	// intermittent: the same run succeeds and fails on identical input depending
	// on whether the list has painted. Give it a few goes before calling it a
	// failure rather than throwing away a whole capture.
	chosen := false

	for attempt := 1; attempt <= 4 && !chosen; attempt++ {
		clicked, err := clickDeep(ctx, "Bearer token")
		if err != nil {
			return err
		}
		if clicked {
			chosen = true
			break
		}
		fmt.Printf("  provisioning form not up yet (attempt %d); reopening\n", attempt)
		if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
			return err
		}
		if err := reopenSavedApp(ctx, env, outDir); err != nil {
			return err
		}
	}

	if !chosen {
		return errors.New("no Bearer token option on the provisioning tab")
	}
	fmt.Println("  chose Bearer token")

	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	base := strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/") + "/scim/v2"
	fields := [][2]string{
		{"Base URL", base},
		{"Token Key", env["EMISAR_SCIM_TOKEN"]},
		// Their docs are explicit that this address must NOT already exist in the
		// target app, or activation fails — and JumpCloud only deletes the probe
		// user when the check passes, so a run that stops midway strands it and
		// every later run is refused. A fresh address per run makes this
		// repeatable; the docs shot shows a plain one because the host is
		// de-identified afterwards anyway.
		{"Test User Email", probeAddress()},
	}
	for _, f := range fields {
		if err := focusField(ctx, f[0]); err != nil {
			return err
		}
		if err := chromedp.Run(ctx, chromedp.KeyEvent(f[1])); err != nil {
			return err
		}
		fmt.Printf("  typed %s\n", f[0])
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	// Configure, TEST, then ACTIVATE — all against the tunnel that is actually
	// serving. The screenshots come afterwards, from the saved configuration, with
	// only the hostname swapped.
	//
	// Doing it the other way round could never work: de-identification rewrites the
	// Base URL field, Activate persists whatever the field holds, and JumpCloud
	// then tested https://emisar.dev — the live product host — with a development
	// token. It refused to activate, correctly.
	// No separate Test Connection press here. Activate on the freshly filled form
	// runs the check AND activates — that is the one sequence observed to reach an
	// active state. Testing first left the form saved-but-inactive, with the footer
	// offering only Test Connection and no way back to Activate.

	// Test, then activate — and JumpCloud asks for that order again on the SAVED
	// form. Pressing Activate on the freshly filled form persists the
	// configuration and leaves the footer offering Test Connection, so a single
	// press was never going to reach an active state. Drive whichever button the
	// footer is currently offering until the badge flips.
	if err := activateProvisioning(ctx, 4); err != nil {
		_ = screenshot(ctx, outDir, "jc-11-never-activated")
		return err
	}
	fmt.Println("  provisioning is active")

	// Now the pictures, from the configuration JumpCloud actually accepted.
	if err := expandConfigurationSettings(ctx); err != nil {
		return err
	}

	docsHost := env["EMISAR_DOCS_HOST"]
	if docsHost == "" {
		docsHost = "emisar.dev"
	}
	tunnel := strings.TrimPrefix(strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/"), "https://")
	if err := deidentifyHost(ctx, tunnel, strings.TrimPrefix(docsHost, "https://")); err != nil {
		return err
	}

	for _, label := range []string{"Base URL", "Token Key"} {
		if err := highlight(ctx, label); err != nil {
			return err
		}
	}
	if err := screenshot(ctx, outDir, "jc-10-scim-filled"); err != nil {
		return err
	}

	// The outcome IS the evidence for the next step: provisioning flips to Active
	// once the connection is accepted, so that badge is what it is about.
	if err := highlight(ctx, "Provisioning Active"); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-11-activate"); err != nil {
		return err
	}

	return describePage(ctx)
}

// probeAddress is the throwaway JumpCloud provisions and deletes as its live
// check. Unique per run: the previous fixed address survives a run that stops
// before the delete, and JumpCloud then refuses to activate against it forever.
func probeAddress() string {
	return fmt.Sprintf("jumpcloud-probe-%d@northstar.example", time.Now().Unix())
}

// expandConfigurationSettings opens the saved provisioning configuration, which
// JumpCloud collapses once it is active — the fields the guide points at are
// inside it.
func expandConfigurationSettings(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  if (/Base URL/.test(document.body.innerText)) return true;
  const header = [...document.querySelectorAll('*')]
    .find(el => visible(el) && !el.querySelector('*') && (el.textContent || '').trim() === 'Configuration Settings');
  if (!header) return false;
  (header.closest('button,[role=button],div') || header).click();
  return true;
})()`
	var opened bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &opened)); err != nil {
		return err
	}
	if !opened {
		return errors.New("could not open the saved Configuration Settings")
	}
	return chromedp.Run(ctx, chromedp.Sleep(4*time.Second))
}

// activateProvisioning presses whichever of Test Connection / Activate the footer
// offers, until provisioning reports active. A real mouse click at the control's
// coordinates: a synthetic click on these footer buttons reports success and does
// nothing.
func activateProvisioning(ctx context.Context, rounds int) error {
	for round := 1; round <= rounds; round++ {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, "Provisioning Active") {
			return nil
		}

		// ACTIVATE when it is offered. On the freshly filled form that one press
		// both checks the connection and activates — the only sequence observed to
		// reach an active state. Test Connection is the fallback for a form that has
		// already been saved.
		pressed, err := pressFooterButton(ctx, "activate")
		if err != nil {
			return err
		}
		if !pressed {
			if pressed, err = pressFooterButton(ctx, "test connection"); err != nil {
				return err
			}
		}
		if !pressed {
			return errors.New("the provisioning footer offers neither Test Connection nor Activate")
		}

		if err := chromedp.Run(ctx, chromedp.Sleep(20*time.Second)); err != nil {
			return err
		}
		if err := waitForProvisioningActive(ctx, 40*time.Second); err == nil {
			return nil
		}
	}
	return errors.New("provisioning never reported active")
}

func pressFooterButton(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const wanted = %q;
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const button = [...document.querySelectorAll('button')]
    .find(el => visible(el) && !el.disabled && (el.textContent || '').trim().toLowerCase() === wanted);
  if (!button) return '';
  const box = button.getBoundingClientRect();
  return JSON.stringify({x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2)});
})()`, label)

	var located string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &located)); err != nil {
		return false, err
	}
	if located == "" {
		return false, nil
	}

	var at struct{ X, Y float64 }
	if err := json.Unmarshal([]byte(located), &at); err != nil {
		return false, err
	}
	if err := chromedp.Run(ctx, chromedp.MouseClickXY(at.X, at.Y)); err != nil {
		return false, err
	}
	fmt.Printf("  pressed %q\n", label)
	return true, nil
}

// waitForProvisioningActive polls the app's own status badges until provisioning
// reports active, which is what activation actually produces.
func waitForProvisioningActive(ctx context.Context, within time.Duration) error {
	deadline := time.Now().Add(within)

	for {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, "Provisioning Active") {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("provisioning never reported active after Activate was pressed")
		}
		// RELOAD between polls. The badge lives in a single-page app that does not
		// re-render it when activation lands, so polling the same DOM watched a
		// value that was never going to change even after JumpCloud had accepted
		// the configuration.
		if err := chromedp.Run(ctx,
			chromedp.Reload(),
			chromedp.Sleep(6*time.Second)); err != nil {
			return err
		}
	}
}

// clickRadio selects a radio by its label text.
func clickRadio(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const radio = [...document.querySelectorAll('input[type=radio]')].filter(visible).find(el =>
    (el.labels && [...el.labels].some(l => l.textContent.trim().startsWith(%q))));
  if (!radio) return false;
  radio.scrollIntoView({block: 'center'});
  radio.click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// describeFields lists the visible inputs so the provisioning form's real field
// names drive the next step instead of a guess.
func describeFields(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return [...document.querySelectorAll('input,textarea,select')].filter(visible).map(el =>
    [el.tagName, el.type || '', 'name=' + (el.name || '-'), 'id=' + (el.id || '-'),
     'ph=' + (el.placeholder || '-'),
     'label=' + (el.labels && el.labels.length ? el.labels[0].textContent.trim().slice(0,40) : '-')
    ].join(' ')).join('\n');
})()`
	var listing string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &listing)); err != nil {
		return err
	}
	fmt.Println("--- visible fields ---")
	fmt.Println(listing)
	return nil
}

// tickInSection checks the box whose enclosing block carries the given heading —
// the checkbox itself is unlabelled on this wizard.
func tickInSection(ctx context.Context, section string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  for (const box of [...document.querySelectorAll('input[type=checkbox]')].filter(visible)) {
    let node = box;
    for (let up = 0; up < 6 && node; up++) {
      node = node.parentElement;
      if (!node) break;
      if (node.textContent.includes(%q)) {
        if (!box.checked) { box.scrollIntoView({block: 'center'}); box.click(); }
        return true;
      }
    }
  }
  return false;
})()`, section)
	var ticked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &ticked))
	return ticked, err
}

// clickInDialog clicks inside the wizard only. Document-wide matching is what
// walked this driver out of the wizard twice: a loose label hits console chrome
// behind the dialog, and the global search field in the top bar shadows the
// wizard's own. Anchor on the dialog's heading and query within its container.
func clickInDialog(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heading = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').includes('Create New Application Integration'))
    .sort((a, b) => a.textContent.length - b.textContent.length)[0];
  if (!heading) return false;
  // Climb to a container big enough to hold the whole wizard body.
  let root = heading;
  for (let up = 0; up < 8 && root.parentElement; up++) {
    root = root.parentElement;
    if (root.querySelectorAll('button,[role=button],a').length > 3) break;
  }
  const matches = [...root.querySelectorAll('a,button,li,div,span,[role=button]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  // Each catalog tile carries its OWN "Select" control; clicking the tile body
  // only highlights it and leaves Next disabled. Walk up to the tile and press
  // its Select, falling back to the element itself when there is none.
  let node = matches[0];
  for (let up = 0; up < 6 && node; up++) {
    const select = [...node.querySelectorAll('a,button,[role=button]')]
      .find(el => visible(el) && (el.textContent || '').trim() === 'Select');
    if (select) { select.scrollIntoView({block: 'center'}); select.click(); return true; }
    node = node.parentElement;
  }
  matches[0].scrollIntoView({block: 'center'});
  matches[0].click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// describePage dumps the visible copy and controls so a missed selector is
// diagnosable from the log rather than by squinting at a screenshot.
func describePage(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const controls = [...document.querySelectorAll('a,button,input[type=submit],[role=button]')]
    .filter(visible).map(el => (el.textContent || el.value || '').trim()).filter(Boolean);
  return JSON.stringify({
    text: document.body.innerText.replace(/\n{2,}/g, "\n").slice(0, 900),
    controls: [...new Set(controls)].slice(0, 40)
  });
})()`
	var payload string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &payload)); err != nil {
		return err
	}
	fmt.Println("--- page ---")
	fmt.Println(payload)
	return nil
}

// highlight outlines the smallest visible element carrying the label, so a
// screenshot shows WHERE to click rather than leaving the reader to hunt. The
// docs are step-by-step; an unmarked full console screen is not a step.
func highlight(ctx context.Context, label string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('a,button,li,div,span,td,label,[role=option]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  const target = matches[0].closest('li,tr,[role=option],a,button') || matches[0];
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
		// FAIL, don't warn: a highlight that matched nothing ships a screenshot
		// with no outline, which is a broken instruction rather than a cosmetic
		// miss. One reached the docs that way.
		return fmt.Errorf("nothing matching %q to highlight", label)
	}
	fmt.Printf("  highlighted %q\n", label)
	return chromedp.Run(ctx, chromedp.Sleep(800*time.Millisecond))
}

// highlightControl outlines the row holding a checkbox or radio. Those controls
// carry no usable text of their own on this wizard, so `highlight` can't find
// them; anchor on the nearest ancestor that also contains the section wording.
func highlightControl(ctx context.Context, section string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  for (const box of [...document.querySelectorAll('input[type=checkbox],input[type=radio]')].filter(visible)) {
    let node = box;
    for (let up = 0; up < 6 && node; up++) {
      node = node.parentElement;
      if (!node) break;
      if (node.textContent.includes(%q)) {
        node.style.outline = '3px solid #10b981';
        node.style.outlineOffset = '3px';
        node.style.borderRadius = '6px';
        node.scrollIntoView({block: 'center'});
        return true;
      }
    }
  }
  return false;
})()`, section)
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		// FAIL, don't warn: a highlight that matched nothing ships a screenshot
		// with no outline, which is a broken instruction rather than a cosmetic
		// miss. One reached the docs that way.
		return fmt.Errorf("no control near %q to highlight", section)
	}
	fmt.Printf("  highlighted control %q\n", section)
	return chromedp.Run(ctx, chromedp.Sleep(800*time.Millisecond))
}
