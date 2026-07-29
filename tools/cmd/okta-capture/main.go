// Command okta-capture drives a live Okta org's admin console and photographs
// the SCIM setup path, the way ./run capture docs scripts the local Keycloak for
// the OIDC guide. Okta is remote SaaS, so it can't ride the workspace browser
// Session (which is pinned to the portal's base URL) — it owns its own chromedp
// context here.
//
// Auth: /api/v1/authn returns a sessionToken for username+password, which
// /login/sessionCookieRedirect exchanges for the console session cookie. That
// keeps the whole run headless — no MFA prompt on this path.
//
// Reads OKTA_* from portal/.agent/secrets/okta-integrator.env (gitignored).
// DEV ONLY, and it lives in the never-shipped tools module.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

// totpCode computes the current RFC 6238 code. The admin console enforces
// step-up MFA even with a valid org session, so a run can't get in without it.
func totpCode(secret string) (string, error) {
	normalized := strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(secret))
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(normalized)
	if err != nil {
		return "", fmt.Errorf("decoding TOTP secret: %w", err)
	}
	mac := hmac.New(sha1.New, key)
	if err := binary.Write(mac, binary.BigEndian, uint64(time.Now().Unix()/30)); err != nil {
		return "", err
	}
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0F
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7FFFFFFF
	return fmt.Sprintf("%06d", value%1000000), nil
}

// pickGoogleAuthenticator clicks the "Select" beside Google Authenticator on the
// challenge chooser. Okta's widget markup carries no stable hook for the row, so
// match the label and walk up to the button that belongs to it.
const pickGoogleAuthenticator = `(() => {
  const buttons = [...document.querySelectorAll('a,button,input[type=submit]')]
    .filter(el => ((el.textContent || el.value || '').trim() === 'Select'));
  for (const button of buttons) {
    let node = button;
    for (let up = 0; up < 6 && node; up++) {
      node = node.parentElement;
      if (node && node.textContent.includes('Google Authenticator')) { button.click(); return true; }
    }
  }
  return false;
})()`

// submitPasscode types the code into whichever visible field the widget rendered
// and submits it.
func submitPasscode(code string) string {
	return fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const field = [...document.querySelectorAll('input[type=text],input[type=tel],input[type=number],input[type=password]')].find(visible);
  if (!field) return false;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(field, %q);
  field.dispatchEvent(new Event('input', {bubbles: true}));
  field.dispatchEvent(new Event('change', {bubbles: true}));
  const submit = [...document.querySelectorAll('input[type=submit],button')]
    .find(el => visible(el) && /verify|submit|continue|next/i.test((el.textContent || el.value || '')));
  if (submit) { submit.click(); return true; }
  field.form && field.form.submit();
  return true;
})()`, code)
}

func main() {
	var secretsPath, outDir, only, flow string
	var headless bool
	flag.StringVar(&secretsPath, "secrets", "portal/.agent/secrets/okta-integrator.env", "creds env file")
	flag.StringVar(&outDir, "out", "", "directory for captured PNGs")
	flag.StringVar(&only, "only", "", "comma-separated screen names (default: all)")
	// The flow otherwise comes from OKTA_FLOW in the secrets FILE, so exporting it
	// in the shell silently did nothing and the run took the other branch.
	flag.StringVar(&flow, "flow", "", `which walkthrough to capture ("oidc"; default: provisioning)`)
	flag.BoolVar(&headless, "headless", true, "run Chrome headless")
	flag.Parse()

	if outDir == "" {
		fmt.Fprintln(os.Stderr, "-out is required")
		os.Exit(1)
	}
	env, err := readEnv(secretsPath)
	if err != nil {
		fail(err)
	}
	if flow != "" {
		env["OKTA_FLOW"] = flow
	}
	if err := run(env, outDir, only, headless); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "okta-capture:", err)
	os.Exit(1)
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
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		env[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return env, scanner.Err()
}

// sessionToken trades username+password for a one-shot session token.
func sessionToken(env map[string]string) (string, error) {
	payload, err := json.Marshal(map[string]string{
		"username": env["OKTA_ADMIN_USER"],
		"password": env["OKTA_ADMIN_PASSWORD"],
	})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequest(http.MethodPost, env["OKTA_ORG_URL"]+"/api/v1/authn", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", err
	}
	var parsed struct {
		Status       string `json:"status"`
		SessionToken string `json:"sessionToken"`
		ErrorSummary string `json:"errorSummary"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", fmt.Errorf("authn: %s", bytes.TrimSpace(body))
	}
	if parsed.SessionToken == "" {
		return "", fmt.Errorf("authn returned status %q (%s)", parsed.Status, parsed.ErrorSummary)
	}
	return parsed.SessionToken, nil
}

// clearMFA answers the admin console's step-up challenge when it appears. A run
// that already holds a live console session skips straight through.
func clearMFA(ctx context.Context, env map[string]string) error {
	var location string
	if err := chromedp.Run(ctx, chromedp.Location(&location)); err != nil {
		return err
	}
	if strings.Contains(location, "-admin.okta.com/admin/") {
		return nil
	}
	var picked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(pickGoogleAuthenticator, &picked)); err != nil {
		return err
	}
	if picked {
		if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
			return err
		}
	}
	// Codes roll every 30s; a fresh one is generated per attempt so a rollover
	// mid-run retries rather than failing the whole capture.
	for attempt := 0; attempt < 3; attempt++ {
		code, err := totpCode(env["OKTA_TOTP_SECRET"])
		if err != nil {
			return err
		}
		var submitted bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(submitPasscode(code), &submitted)); err != nil {
			return err
		}
		fmt.Printf("  mfa: submitted %s (attempt %d, accepted=%t)\n", code, attempt+1, submitted)
		if err := chromedp.Run(ctx, chromedp.Sleep(6*time.Second)); err != nil {
			return err
		}
		if err := chromedp.Run(ctx, chromedp.Location(&location)); err != nil {
			return err
		}
		if strings.Contains(location, "-admin.okta.com/admin/") {
			return nil
		}
	}
	return fmt.Errorf("MFA not cleared — stuck at %s", location)
}

func run(env map[string]string, outDir, only string, headless bool) error {
	token, err := sessionToken(env)
	if err != nil {
		return err
	}
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
	// The full SCIM flow — sign-in with MFA, credentials, save, then the lifecycle
	// screens — runs past five minutes on a slow console, and the cap cut it off
	// mid-flow rather than failing at a step.
	ctx, cancelTimeout := context.WithTimeout(ctx, 12*time.Minute)
	defer cancelTimeout()

	// The redirect lands on the admin console already authenticated.
	landing := env["OKTA_ADMIN_URL"] + "/admin/apps/active"
	entry := fmt.Sprintf("%s/login/sessionCookieRedirect?token=%s&redirectUrl=%s",
		env["OKTA_ORG_URL"], token, landing)
	if err := chromedp.Run(ctx, chromedp.Navigate(entry)); err != nil {
		return err
	}
	// Okta's console is a SPA; wait for it to paint rather than for load.
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}

	if err := clearMFA(ctx, env); err != nil {
		return err
	}

	var current, title string
	if err := chromedp.Run(ctx,
		chromedp.Location(&current),
		chromedp.Title(&title)); err != nil {
		return err
	}
	fmt.Printf("landed on: %s\n  title: %s\n", current, title)
	if !strings.Contains(current, "-admin.okta.com") {
		return fmt.Errorf("not in the admin console — still at %s", current)
	}

	return captureFlow(ctx, env, outDir, only)
}

// clickText clicks the first visible control whose trimmed label matches, and
// reports whether it found one. Okta's console markup has few stable hooks, so
// the visible label is the most durable selector we have.
func clickText(ctx context.Context, label string) (bool, error) {
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
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// waitForText polls the rendered page until `needle` shows up, so a step waits
// on the thing it needs rather than on a guessed number of seconds. Reports
// whether it appeared instead of erroring, leaving the caller to say what was
// missing — a bare timeout reads as a selector bug and sends the next reader
// hunting the wrong thing.
func waitForText(ctx context.Context, needle string, attempts int) (bool, error) {
	for range attempts {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return false, err
		}
		if strings.Contains(body, needle) {
			return true, nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
			return false, err
		}
	}
	return false, nil
}

// clickContaining clicks the SMALLEST visible element whose text contains the
// label. Typeahead rows and cards bundle a subtitle into the same clickable
// node ("…(Header Auth)SWA, SCIM, SAML"), so exact matching misses them;
// smallest-first avoids clicking a whole container.
func clickContaining(ctx context.Context, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const candidates = [...document.querySelectorAll('a,button,li,div,span,td,[role=option],[role=button],[role=menuitem]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!candidates.length) return false;
  candidates.sort((a, b) => a.textContent.length - b.textContent.length);
  const target = candidates[0];
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
})()`, label)
	var clicked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked))
	return clicked, err
}

// typeInto sets a field found by placeholder, name, id, or preceding label.
func typeInto(ctx context.Context, hint, value string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hint = %q.toLowerCase();
  const fields = [...document.querySelectorAll('input,textarea')].filter(visible);
  const match = fields.find(el =>
    (el.name || '').toLowerCase().includes(hint) ||
    (el.id || '').toLowerCase().includes(hint) ||
    (el.placeholder || '').toLowerCase().includes(hint) ||
    (el.getAttribute('aria-label') || '').toLowerCase().includes(hint) ||
    (el.labels && [...el.labels].some(l => l.textContent.toLowerCase().includes(hint))));
  if (!match) return false;
  const setter = Object.getOwnPropertyDescriptor(
    match.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype, 'value').set;
  match.scrollIntoView({block: 'center'});
  setter.call(match, %q);
  match.dispatchEvent(new Event('input', {bubbles: true}));
  match.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
})()`, hint, value)
	var typed bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &typed))
	return typed, err
}

// captureFlow walks the SCIM setup path an emisar customer follows, pausing at
// each screen the docs page teaches. Okta's console is a SPA, so every step
// settles on a sleep rather than a load event.
func captureFlow(ctx context.Context, env map[string]string, outDir, only string) error {
	wanted := map[string]bool{}
	for _, name := range strings.Split(only, ",") {
		if trimmed := strings.TrimSpace(name); trimmed != "" {
			wanted[trimmed] = true
		}
	}
	// clearMFA here too, not just in step(): Okta re-challenges on privileged
	// navigation, so a shot taken right after a Save can otherwise photograph the
	// "Verify with Google Authenticator" screen instead of the destination. That
	// shipped once, captioned as the client-credentials page.
	shoot := func(name string) error {
		if len(wanted) > 0 && !wanted[name] {
			return nil
		}
		if err := clearMFA(ctx, env); err != nil {
			return err
		}
		return screenshot(ctx, outDir, name)
	}
	settle := func(seconds int) error {
		return chromedp.Run(ctx, chromedp.Sleep(time.Duration(seconds)*time.Second))
	}
	// Okta re-challenges MFA on privileged navigation, not just at sign-in, so
	// every step re-checks before acting. clearMFA is a cheap no-op once we're
	// already inside the console.
	step := func(label string) error {
		if err := clearMFA(ctx, env); err != nil {
			return err
		}
		clicked, err := clickText(ctx, label)
		if err != nil {
			return err
		}
		if !clicked {
			return fmt.Errorf("could not find %q", label)
		}
		fmt.Printf("  clicked %q\n", label)
		return settle(5)
	}

	if env["OKTA_FLOW"] == "oidc" {
		return oidcFlow(ctx, env, shoot, step, settle)
	}

	// Resuming against an app that already exists: skip creation (Okta would
	// happily make a duplicate) and go straight to its Provisioning tab.
	if env["OKTA_SCIM_APP_ID"] != "" {
		return provisioningFlow(ctx, env, shoot, step, settle)
	}

	if err := shoot("01-applications"); err != nil {
		return err
	}
	if err := step("Browse App Catalog"); err != nil {
		return err
	}
	// Real key events, not a JS-set value: the catalog list is React-driven and
	// only filters on genuine keystrokes.
	if err := focusField(ctx, "search"); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent("SCIM 2.0 Test App")); err != nil {
		return err
	}
	if err := settle(5); err != nil {
		return err
	}
	// Five near-identical SCIM apps come back; ring the one to pick.
	if err := highlight(ctx, "SCIM 2.0 Test App (Header Auth)"); err != nil {
		return err
	}
	if err := shoot("02-catalog-search"); err != nil {
		return err
	}

	pickedApp, err := clickContaining(ctx, "SCIM 2.0 Test App (Header Auth)")
	if err != nil {
		return err
	}
	if !pickedApp {
		return fmt.Errorf("no typeahead row for SCIM 2.0 Test App (Header Auth)")
	}
	fmt.Println(`  clicked "SCIM 2.0 Test App (Header Auth)"`)
	if err := settle(6); err != nil {
		return err
	}
	if err := shoot("03-app-overview"); err != nil {
		return err
	}
	if err := step("Add Integration"); err != nil {
		return err
	}
	if err := shoot("04-general-settings"); err != nil {
		return err
	}
	if _, err := typeInto(ctx, "label", "emisar directory sync"); err != nil {
		return err
	}
	if err := step("Next"); err != nil {
		return err
	}
	if err := shoot("05-sign-on-options"); err != nil {
		return err
	}
	if err := step("Done"); err != nil {
		return err
	}
	if err := shoot("06-app-created"); err != nil {
		return err
	}
	return reportPage(ctx)
}

// provisioningFlow captures the half that actually wires Okta to emisar: the
// API-integration form, the credential test, and the To App lifecycle settings.
func provisioningFlow(
	ctx context.Context,
	env map[string]string,
	shoot func(string) error,
	step func(string) error,
	settle func(int) error,
) error {
	instance := fmt.Sprintf("%s/admin/app/%s/instance/%s/#tab-provisioning",
		env["OKTA_ADMIN_URL"], env["OKTA_SCIM_APP_NAME"], env["OKTA_SCIM_APP_ID"])
	if err := chromedp.Run(ctx, chromedp.Navigate(instance)); err != nil {
		return err
	}
	if err := settle(8); err != nil {
		return err
	}
	if err := clearMFA(ctx, env); err != nil {
		return err
	}
	if err := settle(3); err != nil {
		return err
	}
	// A fresh load ignores the #tab-provisioning fragment, so switch tabs by hand.
	if err := step("Provisioning"); err != nil {
		return err
	}
	if err := shoot("07-provisioning-tab"); err != nil {
		return err
	}

	// Re-runs land on an already-configured app, where this button no longer
	// exists — the credential screens are captured, so skip to the lifecycle half
	// rather than failing the whole run.
	configuring, err := clickText(ctx, "Configure API Integration")
	if err != nil {
		return err
	}
	if !configuring {
		fmt.Println("  already configured — skipping to To App")
		return lifecycleFlow(ctx, instance, shoot, step, settle)
	}
	if err := settle(5); err != nil {
		return err
	}
	if err := shoot("08-configure-api-integration"); err != nil {
		return err
	}

	// The checkbox reveals the credential fields; without it they aren't rendered.
	if err := tickEnableAPIIntegration(ctx); err != nil {
		return err
	}
	if err := settle(2); err != nil {
		return err
	}
	// Field names read off the live form: the labels are decorative, the names
	// are what identify them.
	// Real keystrokes, not a JS-set value: this form is React-controlled, so a
	// programmatic assignment never reaches its state and Okta posts an empty
	// credential (which emisar correctly rejects as a malformed bearer).
	base := strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/") + "/scim/v2"
	if err := typeRealKeys(ctx, "scim_base_url", base); err != nil {
		return err
	}
	if err := typeRealKeys(ctx, "scim_auth_header_value", env["EMISAR_SCIM_TOKEN"]); err != nil {
		return err
	}
	if err := settle(1); err != nil {
		return err
	}
	if err := shoot("09-api-credentials-filled"); err != nil {
		return err
	}

	if err := clickSelector(ctx, "#m-verify-button"); err != nil {
		return err
	}
	fmt.Println("  clicked Test API Credentials")
	if err := settle(10); err != nil {
		return err
	}
	// The verification above was real, against the tunnel. Swap the rig's hostname
	// for the product one now that it has served its purpose.
	docsHost := env["EMISAR_DOCS_HOST"]
	if docsHost == "" {
		docsHost = "https://emisar.dev"
	}
	tunnel := strings.TrimPrefix(strings.TrimSuffix(env["EMISAR_PUBLIC_URL"], "/"), "https://")
	if err := deidentifyHost(ctx, tunnel, strings.TrimPrefix(docsHost, "https://")); err != nil {
		return err
	}
	// Centre the confirmation itself — a plain scroll-to-top leaves it under the
	// sticky app header.
	if err := scrollToText(ctx, "was verified successfully"); err != nil {
		return err
	}
	if err := settle(2); err != nil {
		return err
	}
	// The step names three controls the reader has to find on this screen: the two
	// fields they paste emisar's values into, and the button that proves the pair
	// works. Outline each.
	for _, label := range []string{"Base URL", "API Token"} {
		if err := highlightGroup(ctx, label, "Enter your"); err != nil {
			return err
		}
	}
	if err := highlight(ctx, "Test API Credentials"); err != nil {
		return err
	}
	if err := shoot("10-test-api-credentials"); err != nil {
		return err
	}

	// The de-identification above rewrote the Base URL field for the screenshot.
	// Saving now would persist THAT hostname, Okta would re-validate against a host
	// with no SCIM provider behind it, and provisioning would silently stay off —
	// which is exactly how a passing "verified successfully!" ended with
	// "Provisioning is not enabled". Put the real tunnel back before saving.
	if err := typeRealKeys(ctx, "scim_base_url", base); err != nil {
		return err
	}
	if err := settle(1); err != nil {
		return err
	}
	if err := clickSelector(ctx, "#userMgmtSettings\\.button\\.submit"); err != nil {
		return err
	}
	fmt.Println("  clicked Save (with the real base URL restored)")
	if err := settle(8); err != nil {
		return err
	}
	if err := shoot("11-provisioning-saved"); err != nil {
		return err
	}

	return lifecycleFlow(ctx, instance, shoot, step, settle)
}

// lifecycleFlow captures Provisioning → To App, Assignments and Push Groups —
// the settings that decide what Okta actually pushes to emisar.
func lifecycleFlow(
	ctx context.Context,
	instance string,
	shoot func(string) error,
	step func(string) error,
	settle func(int) error,
) error {
	// The two callers arrive with the Integration pane in different states — a
	// fresh save has just re-rendered it, a re-run never left it — so the
	// precondition belongs here rather than in each caller. Re-enter Provisioning,
	// then WAIT for the Settings list instead of guessing at a settle: the re-run
	// path guessed, and failed with a bare "could not find To App".
	if err := chromedp.Run(ctx, chromedp.Navigate(instance)); err != nil {
		return err
	}
	if err := settle(8); err != nil {
		return err
	}
	if err := step("Provisioning"); err != nil {
		return err
	}
	// To App / To Okta only exist once the API integration SAVED, and Okta refuses
	// to save it unless Test API Credentials passed — which needs emisar actually
	// reachable. Without a tunnel the pane reads "Provisioning is not enabled" and
	// the missing tab looks like a selector bug; it is not. Say so here, because
	// three rounds were spent adding waits and retries to a downstream symptom.
	var body string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
		return err
	}
	if strings.Contains(body, "Provisioning is not enabled") {
		_ = shoot("12-provisioning-not-enabled")
		return fmt.Errorf("provisioning never enabled — Test API Credentials must PASS first, " +
			"which needs EMISAR_PUBLIC_URL reachable from Okta (start the tunnel)")
	}
	// The Settings list paints asynchronously after the tab switch, so poll for it
	// rather than clicking into a pane that has not rendered yet.
	shown, err := waitForText(ctx, "To App", 10)
	if err != nil {
		return err
	}
	if !shown {
		_ = shoot("12-to-app-missing")
		_ = reportPage(ctx)
		return fmt.Errorf("the Settings list never rendered — To App absent after re-entering Provisioning")
	}
	if err := step("To App"); err != nil {
		_ = shoot("12-to-app-missing")
		_ = reportPage(ctx)
		return err
	}
	if err := step("Edit"); err != nil {
		return err
	}
	if err := settle(2); err != nil {
		return err
	}
	for _, label := range []string{"Create Users", "Update User Attributes", "Deactivate Users"} {
		ticked, err := tickInSection(ctx, label)
		if err != nil {
			return err
		}
		fmt.Printf("  enable %s: %t\n", label, ticked)
	}
	if err := settle(2); err != nil {
		return err
	}
	for _, label := range []string{"Create Users", "Update User Attributes", "Deactivate Users"} {
		checked, err := sectionChecked(ctx, label)
		if err != nil {
			return err
		}
		if !checked {
			return fmt.Errorf("%s did not stick — the form still shows it unticked", label)
		}
	}
	fmt.Println("  all three lifecycle operations verified ON")
	// One outline per control the step tells the operator to touch — including
	// Sync Password, which the step says to LEAVE OFF and which the reader has to
	// find to confirm that. Spanning the whole panel in a single group needed a
	// climb deeper than the helper walks, so it silently marked nothing.
	for _, label := range []string{
		"Create Users",
		"Update User Attributes",
		"Deactivate Users",
		"Sync Password",
	} {
		if err := highlightGroup(ctx, label, "Enable"); err != nil {
			return err
		}
	}
	if err := shoot("12-to-app-settings"); err != nil {
		return err
	}
	if err := step("Save"); err != nil {
		return err
	}
	if err := settle(5); err != nil {
		return err
	}

	// The two lists are empty at this point in the walkthrough — nobody has been
	// assigned yet, which is the whole reason the step exists — so the shot has
	// to point at the control that fills them, not at the table.
	if err := step("Assignments"); err != nil {
		return err
	}
	if err := settle(3); err != nil {
		return err
	}
	if err := highlight(ctx, "Assign"); err != nil {
		return err
	}
	if err := shoot("13-assignments"); err != nil {
		return err
	}
	if err := step("Push Groups"); err != nil {
		return err
	}
	if err := settle(3); err != nil {
		return err
	}
	if err := highlight(ctx, "Push Groups"); err != nil {
		return err
	}
	if err := shoot("14-push-groups"); err != nil {
		return err
	}
	return reportPage(ctx)
}

// clickRadio selects the radio whose label starts with the given text.
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

// tickInSection checks the box belonging to a named setting. Approach from the
// HEADING down, not the checkbox up: find the smallest node carrying the setting
// name, then climb until the container holds exactly one checkbox — that is the
// setting's own row. The old climb-from-checkbox missed Update User Attributes
// and Deactivate Users, and the shipped screenshot showed them unticked.
func tickInSection(ctx context.Context, section string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heads = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  let node = heads[0];
  if (!node) return false;
  for (let up = 0; up < 8 && node; up++) {
    const boxes = node.querySelectorAll('input[type=checkbox]');
    if (boxes.length === 1) {
      const box = boxes[0];
      if (!box.checked) { box.scrollIntoView({block: 'center'}); box.click(); }
      return true;
    }
    if (boxes.length > 1) return false;
    node = node.parentElement;
  }
  return false;
})()`, section)
	var ticked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &ticked))
	return ticked, err
}

// sectionChecked reports whether a setting's own checkbox is REALLY checked —
// a click helper returning true only means something matched, never that the
// control took the value.
func sectionChecked(ctx context.Context, section string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heads = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  let node = heads[0];
  if (!node) return false;
  for (let up = 0; up < 8 && node; up++) {
    const boxes = node.querySelectorAll('input[type=checkbox]');
    if (boxes.length === 1) return boxes[0].checked;
    if (boxes.length > 1) return false;
    node = node.parentElement;
  }
  return false;
})()`, section)
	var checked bool
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &checked))
	return checked, err
}

// highlightGroup outlines the container holding BOTH anchor and companion text —
// the wide highlight that frames a full control group rather than one label.
func highlightGroup(ctx context.Context, anchor, mustInclude string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hits = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q))
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  let node = hits[0];
  if (!node) return false;
  for (let up = 0; up < 10 && node; up++) {
    if ((node.textContent || '').includes(%q)) break;
    node = node.parentElement;
  }
  if (!node) return false;
  // An outline on an INLINE element is drawn per line box, so a wrapped span
  // comes out as a stack of horizontal bars with no sides. Climb to a block-level
  // box tall enough to be the row itself.
  for (let up = 0; up < 4 && node.parentElement; up++) {
    const display = getComputedStyle(node).display;
    const block = display === 'block' || display === 'flex' || display === 'grid' ||
                  display === 'list-item' || display === 'table-row';
    if (block && node.getBoundingClientRect().height >= 24) break;
    node = node.parentElement;
  }
  node.scrollIntoView({block: 'center'});
  // A table row is the other way to get bars with no sides: an outline on a <tr>
  // renders only its horizontal segments, and this shot shipped looking like a
  // set of underlines because of it. Ring the CELLS instead.
  if (getComputedStyle(node).display === 'table-row') {
    const cells = [...node.children];
    if (!cells.length) return false;
    cells.forEach((cell, i) => {
      const ring = ['inset 0 3px 0 #10b981', 'inset 0 -3px 0 #10b981'];
      if (i === 0) ring.push('inset 3px 0 0 #10b981');
      if (i === cells.length - 1) ring.push('inset -3px 0 0 #10b981');
      cell.style.boxShadow = ring.join(', ');
    });
    return true;
  }
  node.style.outline = '3px solid #10b981';
  node.style.outlineOffset = '3px';
  node.style.borderRadius = '6px';
  const box = node.getBoundingClientRect();
  return node.tagName + ' display=' + getComputedStyle(node).display +
    ' ' + Math.round(box.width) + 'x' + Math.round(box.height);
})()`, anchor, mustInclude)
	var marked string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	// FAIL, don't warn. This printed the result and carried on, so a highlight
	// that matched nothing shipped a screenshot with no outline on it — which is
	// exactly how the "Provisioning to App" shot reached the docs bare. A missing
	// outline is a broken instruction, not a cosmetic miss.
	if marked == "" {
		return fmt.Errorf("nothing spanning %q..%q to highlight", anchor, mustInclude)
	}
	fmt.Printf("  highlighted group %q..%q on %s\n", anchor, mustInclude, marked)
	return chromedp.Run(ctx, chromedp.Sleep(600*time.Millisecond))
}

// typeRealKeys focuses a field and types with genuine key events, clearing what
// was there first. Use it for anything React controls.
func typeRealKeys(ctx context.Context, hint, value string) error {
	if err := focusField(ctx, hint); err != nil {
		return err
	}
	// select() above highlights existing text; typing replaces it.
	if err := chromedp.Run(ctx, chromedp.KeyEvent(value)); err != nil {
		return err
	}
	fmt.Printf("  typed into %s\n", hint)
	return nil
}

// clearOtherURIFields blanks every `uri` box except the sign-in redirect one we
// just filled, so Okta's localhost defaults don't survive into a screenshot.
func clearOtherURIFields(ctx context.Context, keepPrefix string) error {
	script := fmt.Sprintf(`(() => {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  let cleared = 0;
  for (const el of document.querySelectorAll('input[name=uri]')) {
    if ((el.value || '').startsWith(%q)) continue;
    if (!el.value) continue;
    setter.call(el, '');
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    cleared++;
  }
  return cleared;
})()`, keepPrefix)
	var cleared int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &cleared)); err != nil {
		return err
	}
	fmt.Printf("  cleared %d prefilled URI field(s)\n", cleared)
	return nil
}

// deidentifyHost rewrites the tunnel hostname to the real product host for the
// screenshot only, and ONLY after the live call has already happened. This is
// de-identification (host/key/UUID), not fabrication: the verification really
// occurred, and the tunnel name is an artifact of the capture rig that no
// customer would ever see — theirs reads emisar.dev. Never use this to change an
// outcome, a status, or any value that carries meaning.
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
      node.nodeValue = node.nodeValue.split(from).join(to);
      changed++;
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

// highlight rings the element a step is about, so a reader's eye lands on the
// right row instead of scanning a vendor console. Emerald is emisar's accent, so
// the marker reads as ours rather than as part of the vendor UI.
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
		return fmt.Errorf("nothing matching %q to highlight", label)
	}
	fmt.Printf("  highlighted %q\n", label)
	return chromedp.Run(ctx, chromedp.Sleep(1200*time.Millisecond))
}

// scrollToText centres the block containing the given label. A full-page shot
// otherwise captures wherever the SPA happened to leave the viewport — which is
// how a "sign-in redirect URI" screenshot ended up showing Trusted Origins.
func scrollToText(ctx context.Context, label string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('label,legend,h1,h2,h3,div,span')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  matches[0].scrollIntoView({block: 'center'});
  return true;
})()`, label)
	var scrolled bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &scrolled)); err != nil {
		return err
	}
	if !scrolled {
		return fmt.Errorf("nothing labelled %q to scroll to", label)
	}
	return chromedp.Run(ctx, chromedp.Sleep(1500*time.Millisecond))
}

// clickSelector clicks an exact CSS selector, for controls whose visible label
// isn't a reliable handle (Okta's form buttons are inputs with generated names).
func clickSelector(ctx context.Context, selector string) error {
	script := fmt.Sprintf(`(() => {
  const el = document.querySelector(%q);
  if (!el) return false;
  el.scrollIntoView({block: 'center'});
  el.click();
  return true;
})()`, selector)
	var clicked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked)); err != nil {
		return err
	}
	if !clicked {
		return fmt.Errorf("selector %s not found", selector)
	}
	return nil
}

// tickEnableAPIIntegration checks the box that reveals Base URL / API Token.
func tickEnableAPIIntegration(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const boxes = [...document.querySelectorAll('input[type=checkbox]')].filter(visible);
  const target = boxes.find(el =>
    (el.labels && [...el.labels].some(l => /enable api integration/i.test(l.textContent))) ||
    /enable/i.test(el.name || '') || /enable/i.test(el.id || ''));
  if (!target) return false;
  if (!target.checked) { target.scrollIntoView({block: 'center'}); target.click(); }
  return true;
})()`
	var ticked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &ticked)); err != nil {
		return err
	}
	if !ticked {
		return fmt.Errorf("enable API Integration checkbox not found")
	}
	fmt.Println("  ticked Enable API Integration")
	return nil
}

// oidcFlow captures the sign-in half: a confidential OIDC web app whose only
// redirect URI is emisar's callback. Separate from the SCIM app by necessity —
// Okta won't put provisioning on an OIDC integration.
// oidcCredentialsShot photographs the two values the operator carries back to
// emisar, on the OIDC app that is already there. Kept separate from the creation
// walkthrough above precisely so the walkthrough can cancel: nothing in this
// capture needs a freshly minted app, and minting one per run littered the org.
func oidcCredentialsShot(
	ctx context.Context,
	env map[string]string,
	shoot func(string) error,
	settle func(int) error,
) error {
	if err := chromedp.Run(ctx, chromedp.Navigate(env["OKTA_ADMIN_URL"]+"/admin/apps/active")); err != nil {
		return err
	}
	if err := settle(8); err != nil {
		return err
	}
	if err := clearMFA(ctx, env); err != nil {
		return err
	}
	// Wait for the list to paint before clicking into it — the click otherwise
	// lands on nothing and the failure only surfaces two steps later.
	listed, err := waitForText(ctx, "emisar", 10)
	if err != nil {
		return err
	}
	if !listed {
		_ = reportPage(ctx)
		return fmt.Errorf("the applications list never rendered")
	}
	// The OIDC app is named "emisar"; the SCIM one is "SCIM 2.0 Test App (Header
	// Auth)", so an exact-text match cannot pick the wrong one.
	opened, err := clickText(ctx, "emisar")
	if err != nil {
		return err
	}
	if !opened {
		_ = reportPage(ctx)
		return fmt.Errorf("no OIDC app named %q in the applications list", "emisar")
	}
	if err := settle(8); err != nil {
		return err
	}
	if err := clearMFA(ctx, env); err != nil {
		return err
	}
	// Wait for the card, do not guess at a settle: the first run highlighted
	// nothing because both lookups ran while the app page was still painting,
	// then the screenshot caught it fully loaded and looked simply un-highlighted.
	shown, err := waitForText(ctx, "Client Credentials", 10)
	if err != nil {
		return err
	}
	if !shown {
		return fmt.Errorf("the app's Client Credentials card never rendered")
	}
	// Box what the step says to copy — the id with its help text, and the secrets
	// table — rather than the whole Client Credentials card, which would swallow
	// the settings the reader must NOT touch.
	if err := highlightGroup(ctx, "Client ID", "required for all"); err != nil {
		return err
	}
	// Anchor INSIDE the secrets block, not on its heading: climbing from the
	// heading reached a container that also held Client authentication and PKCE —
	// the two settings this step tells the reader to leave alone.
	if err := highlightGroup(ctx, "Generate new secret", "Creation date"); err != nil {
		return err
	}
	if err := shoot("oidc-04-client-credentials"); err != nil {
		return err
	}
	return reportPage(ctx)
}

func oidcFlow(
	ctx context.Context,
	env map[string]string,
	shoot func(string) error,
	step func(string) error,
	settle func(int) error,
) error {
	if err := step("Create App Integration"); err != nil {
		return err
	}
	// Radios, not links: clicking the label text leaves the input unselected and
	// Next silently refuses. The application-type choice only renders once a
	// sign-in method is picked.
	if picked, err := clickRadio(ctx, "OIDC - OpenID Connect"); err != nil {
		return err
	} else if !picked {
		return fmt.Errorf("sign-in method OIDC not offered")
	}
	if err := settle(3); err != nil {
		return err
	}
	if picked, err := clickRadio(ctx, "Web Application"); err != nil {
		return err
	} else if !picked {
		return fmt.Errorf("application type Web Application not offered")
	}
	if err := settle(2); err != nil {
		return err
	}
	// Shot AFTER both radios are set — a blank dialog doesn't show the reader
	// which options to pick, which is the whole point of this screen. Box each
	// chosen option TOGETHER WITH its help text: the radio label alone is a
	// hairline in a dialog of eight near-identical rows.
	if err := highlightGroup(ctx, "OIDC - OpenID Connect", "Okta Sign-In Widget"); err != nil {
		return err
	}
	if err := highlightGroup(ctx, "Web Application", "Node.js, PHP"); err != nil {
		return err
	}
	if err := shoot("oidc-01-create-dialog"); err != nil {
		return err
	}
	if err := step("Next"); err != nil {
		return err
	}
	if err := typeRealKeys(ctx, "client_name", "emisar"); err != nil {
		return err
	}
	// Okta never dials the redirect URI — the browser does — so screenshots show the
	// real hosted product URL rather than whatever tunnel this run used.
	host := env["EMISAR_DOCS_HOST"]
	if host == "" {
		host = "https://emisar.dev"
	}
	// The first `uri` box is Sign-in redirect URIs. emisar's callback is fixed and
	// must be the ONLY entry — no wildcard.
	if err := typeRealKeysSelector(ctx, "input[name=uri]", host+"/sign_in/sso/callback"); err != nil {
		return err
	}
	// Okta pre-fills the sign-out box with http://localhost:8080; emisar doesn't
	// use it, and it makes the screenshot look like someone's laptop.
	if err := clearOtherURIFields(ctx, host); err != nil {
		return err
	}
	// Assignment is emisar's job via group→role mapping, so don't grant the whole
	// org here.
	if picked, err := clickRadio(ctx, "Skip group assignment for now"); err != nil {
		return err
	} else if !picked {
		fmt.Println("  (no group-assignment radio; leaving default)")
	}
	if err := settle(2); err != nil {
		return err
	}
	// Frame the shot on the redirect URIs — the thing this step is about — and
	// box BOTH things the step's prose asks for: the grant type it leaves alone
	// and the callback it fills in. Each box takes the whole labelled row, so it
	// frames the area to look at instead of sitting on top of the words.
	if err := scrollToText(ctx, "Sign-in redirect URIs"); err != nil {
		return err
	}
	if err := highlightGroup(ctx, "Authorization Code", "Grant type"); err != nil {
		return err
	}
	// Match on "Add URI", not the URL: the callback lives in an <input value=…>,
	// which is NOT part of textContent, so climbing for it never matched and the
	// outline ended up around a page-level container. "Add URI" is real text in
	// the same row's right-hand column.
	if err := highlightGroup(ctx, "Sign-in redirect URIs", "Add URI"); err != nil {
		return err
	}
	if err := shoot("oidc-03-new-web-app"); err != nil {
		return err
	}
	// CANCEL, not Save. This form is only reachable while creating an app, so
	// saving it would mint a duplicate "emisar" integration on every capture run
	// — the credentials shot below comes from the app that already exists.
	if err := step("Cancel"); err != nil {
		return err
	}
	if err := settle(5); err != nil {
		return err
	}
	return oidcCredentialsShot(ctx, env, shoot, settle)
}

// typeRealKeysSelector types into the first match for a CSS selector, for fields
// that carry no distinguishing name (Okta renders several `uri` boxes).
func typeRealKeysSelector(ctx context.Context, selector, value string) error {
	script := fmt.Sprintf(`(() => {
  const el = document.querySelector(%q);
  if (!el) return false;
  el.scrollIntoView({block: 'center'});
  el.focus();
  el.select && el.select();
  return true;
})()`, selector)
	var focused bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &focused)); err != nil {
		return err
	}
	if !focused {
		return fmt.Errorf("selector %s not found", selector)
	}
	if err := chromedp.Run(ctx, chromedp.KeyEvent(value)); err != nil {
		return err
	}
	fmt.Printf("  typed into %s\n", selector)
	return nil
}

// reportPage prints where the run ended up, so a failed selector is diagnosable
// from the log rather than only from the screenshots.
func reportPage(ctx context.Context) error {
	var location, text string
	if err := chromedp.Run(ctx,
		chromedp.Location(&location),
		chromedp.Evaluate(`document.body.innerText.replace(/\n{2,}/g, "\n").slice(0, 700)`, &text)); err != nil {
		return err
	}
	fmt.Printf("  at %s\n  --- page text ---\n%s\n  ---\n", location, text)
	return nil
}

// focusField puts the cursor in a field so chromedp.KeyEvent types into it with
// real key events (which React-driven lists need in order to filter).
func focusField(ctx context.Context, hint string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hint = %q.toLowerCase();
  const fields = [...document.querySelectorAll('input,textarea')].filter(visible);
  const match = fields.find(el =>
    (el.name || '').toLowerCase().includes(hint) ||
    (el.id || '').toLowerCase().includes(hint) ||
    (el.placeholder || '').toLowerCase().includes(hint) ||
    (el.getAttribute('aria-label') || '').toLowerCase().includes(hint))
    || (hint === 'search' ? fields.find(el => (el.type || '').toLowerCase() === 'search') : null);
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
		return fmt.Errorf("no field matching %q to focus", hint)
	}
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
