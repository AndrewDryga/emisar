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
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	var secretsPath, outDir string
	var headless bool
	flag.StringVar(&secretsPath, "secrets", "portal/.agent/secrets/jumpcloud-trial.env", "creds env file")
	flag.StringVar(&outDir, "out", "", "directory for captured PNGs")
	flag.BoolVar(&headless, "headless", true, "run Chrome headless")
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
	if err := run(env, outDir, headless); err != nil {
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
  if (!match) return false;
  match.scrollIntoView({block: 'center'});
  match.focus();
  match.select && match.select();
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

func run(env map[string]string, outDir string, headless bool) error {
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
	ctx, cancelTimeout := context.WithTimeout(ctx, 4*time.Minute)
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
	return ssoApplicationsFlow(ctx, env, outDir)
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
	if err := screenshot(ctx, outDir, "jc-06-options-chosen"); err != nil {
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
	if err := screenshot(ctx, outDir, "jc-07-general-info"); err != nil {
		return err
	}

	// Step 3 is general info — the wizard never asks SAML vs OIDC; that choice
	// lives on the saved app's SSO tab, which is why the wizard alone cannot
	// settle whether OIDC and provisioning coexist.
	if err := focusField(ctx, "label"); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent("emisar"), chromedp.Sleep(2*time.Second)); err != nil {
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
	if err := screenshot(ctx, outDir, "jc-08-after-save"); err != nil {
		return err
	}
	return provisioningFlow(ctx, env, outDir)
}

// provisioningFlow wires the saved app's Provisioning tab at emisar's SCIM
// endpoint and activates it. Activation is what makes JumpCloud actually push,
// which is the only way to observe what it really sends as externalId — their
// docs describe a fallback, not a guarantee.
func provisioningFlow(ctx context.Context, env map[string]string, outDir string) error {
	// Open the app we just created.
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

// provisioningTabFlow opens the app's provisioning tab and reports its fields.
func provisioningTabFlow(ctx context.Context, env map[string]string, outDir string) error {
	// Their own docs use both names for this tab; try each.
	opened := false
	for _, label := range []string{"Provisioning", "Identity Management"} {
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		if clicked {
			fmt.Printf("  opened %q tab\n", label)
			opened = true
			break
		}
	}
	if !opened {
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

	// SCIM API + Bearer token is emisar's shape; the alternatives are a custom
	// import and an API-key header.
	for _, radio := range []string{"SCIM API", "Bearer token"} {
		picked, err := clickRadio(ctx, radio)
		if err != nil {
			return err
		}
		fmt.Printf("  radio %q: %t\n", radio, picked)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	base := strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/") + "/scim/v2"
	fields := [][2]string{
		{"Base URL", base},
		{"Token Key", env["EMISAR_SCIM_TOKEN"]},
		// Their docs are explicit that this address must NOT already exist in the
		// target app, or activation fails.
		{"Test User Email", "jumpcloud-probe@northstar.example"},
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
	// Swap the capture rig's tunnel hostname for the product one. This is
	// de-identification (host), never an outcome — the values were really typed
	// and the connection really tested against them.
	docsHost := env["EMISAR_DOCS_HOST"]
	if docsHost == "" {
		docsHost = "emisar.dev"
	}
	tunnel := strings.TrimPrefix(strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/"), "https://")
	if err := deidentifyHost(ctx, tunnel, strings.TrimPrefix(docsHost, "https://")); err != nil {
		return err
	}
	if err := screenshot(ctx, outDir, "jc-10-scim-filled"); err != nil {
		return err
	}
	// Test Connection, then Activate. Their form DISCARDS the config if you press
	// Save instead — documented, and worth never learning the hard way.
	for _, label := range []string{"Test Connection", "Activate"} {
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		fmt.Printf("  clicked %q: %t\n", label, clicked)
		if err := chromedp.Run(ctx, chromedp.Sleep(12*time.Second)); err != nil {
			return err
		}
		if err := screenshot(ctx, outDir, "jc-11-"+strings.ToLower(strings.ReplaceAll(label, " ", "-"))); err != nil {
			return err
		}
	}
	return describePage(ctx)
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
