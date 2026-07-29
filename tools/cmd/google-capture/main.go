// Command google-capture drives a live Google Cloud console and photographs
// the Google Auth Platform setup path for the Google Workspace SSO guide.
//
// Reads GOOGLE_* from portal/.agent/secrets/google-workspace.env (gitignored).
// DEV ONLY, and it lives in the never-shipped tools module.
package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

const (
	consoleURL           = "https://console.cloud.google.com/auth/overview"
	docsRedirectURI      = "https://emisar.dev/sign_in/sso/callback"
	redactedUser         = "admin@example.com"
	redactedClientID     = "000000000000-example.apps.googleusercontent.com"
	redactedClientSecret = "GOCSPX-example-redacted-client-secret"
)

func main() {
	envPath := flag.String("env", "portal/.agent/secrets/google-workspace.env", "credential env file")
	outDir := flag.String("out", "", "directory for captured PNGs")
	headless := flag.Bool("headless", true, "run Chrome headless")
	flag.Parse()

	if *outDir == "" {
		fail(fmt.Errorf("-out is required"))
	}
	env, err := readEnv(*envPath)
	if err != nil {
		fail(err)
	}
	for _, key := range []string{"GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_TEST_USER", "GOOGLE_TEST_PASSWORD"} {
		if env[key] == "" {
			fail(fmt.Errorf("%s is missing", key))
		}
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fail(err)
	}
	if err := run(env, *outDir, *headless); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "google-capture:", err)
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
			return nil, fmt.Errorf("invalid env line")
		}
		env[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `'"`)
	}
	return env, scanner.Err()
}

func run(env map[string]string, outDir string, headless bool) error {
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", headless),
		chromedp.Flag("lang", "en-US"),
		chromedp.WindowSize(1440, 1100),
	)
	allocator, cancelAllocator := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAllocator()

	ctx, cancel := chromedp.NewContext(allocator)
	defer cancel()
	ctx, cancelTimeout := context.WithTimeout(ctx, 12*time.Minute)
	defer cancelTimeout()

	projectNumber := strings.SplitN(env["GOOGLE_CLIENT_ID"], "-", 2)[0]
	entry := consoleURL + "?project=" + projectNumber + "&hl=en"
	if err := chromedp.Run(ctx, chromedp.Navigate(entry), chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	if err := signIn(ctx, env); err != nil {
		_ = screenshot(ctx, outDir, "google-failed")
		_ = describePage(ctx, env)
		return err
	}
	if err := authPlatformFlow(ctx, env, outDir); err != nil {
		_ = screenshot(ctx, outDir, "google-failed")
		_ = describePage(ctx, env)
		return err
	}
	return nil
}

func signIn(ctx context.Context, env map[string]string) error {
	deadline := time.Now().Add(4 * time.Minute)
	submittedUser, submittedPassword, submittedTOTP := false, false, false

	for time.Now().Before(deadline) {
		var location, body string
		if err := chromedp.Run(ctx,
			chromedp.Location(&location),
			chromedp.Evaluate(`document.body ? document.body.innerText : ""`, &body),
		); err != nil {
			return err
		}

		switch {
		case strings.Contains(location, "accounts.google.com") && visible(ctx, `#identifierId`) && !submittedUser:
			if err := typeRealKeys(ctx, `#identifierId`, env["GOOGLE_TEST_USER"]); err != nil {
				return fmt.Errorf("filling the Google account identifier: %w", err)
			}
			if err := chromedp.Run(ctx,
				chromedp.Click(`#identifierNext button`, chromedp.ByQuery),
				chromedp.Sleep(4*time.Second),
			); err != nil {
				return err
			}
			submittedUser = true
			fmt.Println("  submitted Google account identifier")

		case strings.Contains(location, "accounts.google.com") && visible(ctx, `input[name="Passwd"]`) && !submittedPassword:
			if err := typeRealKeys(ctx, `input[name="Passwd"]`, env["GOOGLE_TEST_PASSWORD"]); err != nil {
				return fmt.Errorf("filling the Google account password: %w", err)
			}
			if err := chromedp.Run(ctx,
				chromedp.Click(`#passwordNext button`, chromedp.ByQuery),
				chromedp.Sleep(5*time.Second),
			); err != nil {
				return err
			}
			submittedPassword = true
			fmt.Println("  submitted Google account password")

		case strings.Contains(location, "accounts.google.com") && totpField(ctx) != "" && !submittedTOTP:
			if env["GOOGLE_TEST_TOTP_SECRET"] == "" {
				return errors.New("an authenticator code was requested but GOOGLE_TEST_TOTP_SECRET is empty")
			}
			if remaining := 30 - time.Now().Unix()%30; remaining < 8 {
				if err := chromedp.Run(ctx, chromedp.Sleep(time.Duration(remaining+1)*time.Second)); err != nil {
					return err
				}
			}
			code, err := totpCode(env["GOOGLE_TEST_TOTP_SECRET"])
			if err != nil {
				return err
			}
			if err := typeRealKeys(ctx, totpField(ctx), code); err != nil {
				return err
			}
			if err := clickFirstText(ctx, "Next", "Continue"); err != nil {
				return err
			}
			submittedTOTP = true
			if err := chromedp.Run(ctx, chromedp.Sleep(5*time.Second)); err != nil {
				return err
			}
			fmt.Println("  submitted Google authenticator code")

		case strings.Contains(location, "accounts.google.com") && strings.Contains(body, "Simplify your sign-in"):
			if err := clickFirstText(ctx, "Not now"); err != nil {
				return err
			}
			fmt.Println("  declined passkey enrollment")

		case strings.Contains(location, "console.cloud.google.com"):
			if strings.Contains(body, "Terms of Service") && strings.Contains(body, "Agree") {
				return errors.New("accepting the Google Cloud Terms of Service is a human account-level decision")
			}
			if strings.Contains(body, "Google Auth Platform") || strings.Contains(body, "Welcome") ||
				strings.Contains(body, "Select a project") {
				fmt.Println("  signed in to Google Cloud")
				return nil
			}
			if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
				return err
			}

		default:
			if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
				return err
			}
		}
	}
	return errors.New("sign-in to Google Cloud did not finish")
}

func authPlatformFlow(ctx context.Context, env map[string]string, outDir string) error {
	if err := waitForText(ctx, "Google Auth Platform", 90*time.Second); err != nil {
		return err
	}
	if err := waitForText(ctx, "Get started", 20*time.Second); err != nil {
		return fmt.Errorf("the selected project is not at an unconfigured Google Auth Platform start screen: %w", err)
	}
	if err := capture(ctx, env, outDir, "google-01-get-started", textHighlight("Get started")); err != nil {
		return err
	}
	if err := clickExactText(ctx, "Get started"); err != nil {
		return err
	}

	if err := waitForText(ctx, "App information", 30*time.Second); err != nil {
		return err
	}
	if err := fillField(ctx, "App name", "emisar"); err != nil {
		return err
	}
	if err := chooseEmail(ctx, "User support email", env["GOOGLE_TEST_USER"]); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-02-app-information", fieldHighlight("App name", "User support email")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Next"); err != nil {
		return err
	}

	if err := waitForText(ctx, "Audience", 30*time.Second); err != nil {
		return err
	}
	if err := selectRadio(ctx, "Internal"); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-03-audience-internal", textHighlight("Internal")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Next"); err != nil {
		return err
	}

	if err := waitForText(ctx, "Contact Information", 30*time.Second); err != nil {
		return err
	}
	if err := fillField(ctx, "Email addresses", env["GOOGLE_TEST_USER"]); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-04-contact-information", fieldHighlight("Email addresses")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Next"); err != nil {
		return err
	}

	if err := waitForText(ctx, "Finish", 30*time.Second); err != nil {
		return err
	}
	if err := selectCheckbox(ctx); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-05-finish", textHighlight("I agree")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Continue", "Create"); err != nil {
		return err
	}
	if err := waitForText(ctx, "OAuth overview", 45*time.Second); err != nil {
		return err
	}

	if err := clickExactText(ctx, "Clients"); err != nil {
		return err
	}
	if err := waitForText(ctx, "OAuth 2.0 Client IDs", 45*time.Second); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-06-clients", textHighlight("Create client")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Create client", "CREATE OAUTH CLIENT ID"); err != nil {
		return err
	}

	if err := waitForText(ctx, "Create OAuth client ID", 30*time.Second); err != nil {
		return err
	}
	if err := chooseOption(ctx, "Application type", "Web application"); err != nil {
		return err
	}
	if err := fillField(ctx, "Name", "emisar docs capture"); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Add URI"); err != nil {
		return err
	}
	if err := fillField(ctx, "URI", docsRedirectURI); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-07-web-application", fieldHighlight("Application type", "Authorized redirect URIs")); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Create"); err != nil {
		return err
	}

	if err := waitForText(ctx, "OAuth client created", 30*time.Second); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-08-client-created", textHighlight("Client ID", "Client secret")); err != nil {
		return err
	}
	fmt.Println("  capture complete; temporary OAuth client remains for caller cleanup")
	return nil
}

type highlightScript struct {
	script   string
	expected int
}

func textHighlight(labels ...string) highlightScript {
	quoted := make([]string, len(labels))
	for index, label := range labels {
		quoted[index] = fmt.Sprintf("%q", label)
	}
	return highlightScript{
		expected: len(labels),
		script: fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const labels = [%s];
  let marked = 0;
  for (const label of labels) {
    const matches = [...document.querySelectorAll('a,button,label,span,div,li,td,[role=button],[role=radio]')]
      .filter(el => visible(el) && (el.textContent || '').includes(label));
    if (!matches.length) continue;
    matches.sort((a, b) => a.textContent.length - b.textContent.length);
    const target = matches[0].closest('label,a,button,tr,li,[role=radio]') || matches[0];
    target.style.outline = '3px solid #10b981';
    target.style.outlineOffset = '3px';
    target.style.borderRadius = '6px';
    target.scrollIntoView({block: 'center'});
    marked++;
  }
  return marked;
})()`, strings.Join(quoted, ",")),
	}
}

func fieldHighlight(labels ...string) highlightScript {
	quoted := make([]string, len(labels))
	for index, label := range labels {
		quoted[index] = fmt.Sprintf("%q", strings.ToLower(label))
	}
	return highlightScript{
		expected: len(labels),
		script: fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const labels = [%s];
  let marked = 0;
  for (const wanted of labels) {
    const controls = [...document.querySelectorAll('input,textarea,select,[role=combobox]')].filter(visible);
    const control = controls.find(el => {
      const text = [
        el.getAttribute('aria-label') || '', el.placeholder || '', el.name || '', el.id || '',
        ...(el.labels ? [...el.labels].map(label => label.textContent || '') : [])
      ].join(' ').toLowerCase();
      return text.includes(wanted);
    });
    if (!control) continue;
    const target = control.closest('label,fieldset,[role=group],div') || control;
    target.style.outline = '3px solid #10b981';
    target.style.outlineOffset = '3px';
    target.style.borderRadius = '6px';
    target.scrollIntoView({block: 'center'});
    marked++;
  }
  return marked;
})()`, strings.Join(quoted, ",")),
	}
}

func capture(ctx context.Context, env map[string]string, outDir, name string, marker highlightScript) error {
	if err := deidentify(ctx, env); err != nil {
		return fmt.Errorf("%s de-identification: %w", name, err)
	}
	var marked int
	if err := chromedp.Run(ctx, chromedp.Evaluate(marker.script, &marked)); err != nil {
		return err
	}
	if marked != marker.expected {
		return fmt.Errorf("%s: highlighted %d of %d required controls", name, marked, marker.expected)
	}
	fmt.Printf("  highlighted %d control(s)\n", marked)
	if err := chromedp.Run(ctx, chromedp.Sleep(700*time.Millisecond)); err != nil {
		return err
	}
	return screenshot(ctx, outDir, name)
}

func deidentify(ctx context.Context, env map[string]string) error {
	replacements := map[string]string{
		env["GOOGLE_TEST_USER"]:     redactedUser,
		env["GOOGLE_CLIENT_ID"]:     redactedClientID,
		env["GOOGLE_CLIENT_SECRET"]: redactedClientSecret,
	}
	script := `(() => {
  const replacements = REPLACEMENTS;
  const inputSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  const textareaSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
  for (const el of document.querySelectorAll('input,textarea')) {
    let value = el.value || '';
    for (const [from, to] of replacements) if (from) value = value.split(from).join(to);
    if (value !== el.value) (el.tagName === 'TEXTAREA' ? textareaSetter : inputSetter).call(el, value);
  }
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    let value = node.nodeValue || '';
    for (const [from, to] of replacements) if (from) value = value.split(from).join(to);
    node.nodeValue = value;
  }
  return true;
})()`
	pairs := make([]string, 0, len(replacements))
	for from, to := range replacements {
		pairs = append(pairs, fmt.Sprintf("[%q,%q]", from, to))
	}
	script = strings.Replace(script, "REPLACEMENTS", "["+strings.Join(pairs, ",")+"]", 1)
	var ok bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &ok)); err != nil {
		return err
	}
	if !ok {
		return errors.New("rewriting the DOM failed")
	}
	return nil
}

func waitForText(ctx context.Context, wanted string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body ? document.body.innerText : ""`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, wanted) {
			return nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
			return err
		}
	}
	return fmt.Errorf("timed out waiting for %q", wanted)
}

func clickExactText(ctx context.Context, label string) error {
	return clickFirstText(ctx, label)
}

func clickFirstText(ctx context.Context, labels ...string) error {
	for _, label := range labels {
		script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('a,button,[role=button],[role=tab]')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q);
  if (!matches.length) return false;
  matches.sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  matches[0].scrollIntoView({block: 'center'});
  matches[0].click();
  return true;
})()`, label)
		var clicked bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked)); err != nil {
			return err
		}
		if clicked {
			return chromedp.Run(ctx, chromedp.Sleep(2*time.Second))
		}
	}
	return fmt.Errorf("nothing visible matching %q", strings.Join(labels, `" or "`))
}

func fillField(ctx context.Context, label, value string) error {
	selector, err := fieldSelector(ctx, label)
	if err != nil {
		return err
	}
	return typeRealKeys(ctx, selector, value)
}

func fieldSelector(ctx context.Context, label string) (string, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const wanted = %q.toLowerCase();
  const fields = [...document.querySelectorAll('input,textarea')].filter(visible);
  const index = fields.findIndex(el => {
    const text = [
      el.getAttribute('aria-label') || '', el.placeholder || '', el.name || '', el.id || '',
      ...(el.labels ? [...el.labels].map(label => label.textContent || '') : [])
    ].join(' ').toLowerCase();
    return text.includes(wanted);
  });
  return index;
})()`, label)
	var index int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &index)); err != nil {
		return "", err
	}
	if index < 0 {
		return "", fmt.Errorf("no field matching %q", label)
	}
	return fmt.Sprintf(`(//input|//textarea)[%d]`, index+1), nil
}

func typeRealKeys(ctx context.Context, selector, value string) error {
	opts := []chromedp.QueryOption{chromedp.ByQuery}
	if strings.HasPrefix(selector, "(") {
		opts = []chromedp.QueryOption{chromedp.BySearch}
	}
	if err := chromedp.Run(ctx, chromedp.Focus(selector, opts...)); err != nil {
		return err
	}
	for _, character := range value {
		if err := chromedp.Run(ctx, chromedp.KeyEvent(string(character))); err != nil {
			return err
		}
		time.Sleep(20 * time.Millisecond)
	}
	return nil
}

func chooseEmail(ctx context.Context, label, email string) error {
	if err := clickFirstText(ctx, label); err != nil {
		return err
	}
	return clickFirstText(ctx, email)
}

func selectRadio(ctx context.Context, label string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const matches = [...document.querySelectorAll('label,[role=radio]')]
    .filter(el => visible(el) && (el.textContent || '').includes(%q));
  if (!matches.length) return false;
  matches.sort((a, b) => a.textContent.length - b.textContent.length);
  matches[0].click();
  return true;
})()`, label)
	var selected bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &selected)); err != nil {
		return err
	}
	if !selected {
		return fmt.Errorf("no radio matching %q", label)
	}
	return chromedp.Run(ctx, chromedp.Sleep(time.Second))
}

func selectCheckbox(ctx context.Context) error {
	script := `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const box = [...document.querySelectorAll('input[type=checkbox],[role=checkbox]')].find(visible);
  if (!box) return false;
  if (!(box.checked || box.getAttribute('aria-checked') === 'true')) box.click();
  return true;
})()`
	var selected bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &selected)); err != nil {
		return err
	}
	if !selected {
		return fmt.Errorf("no visible agreement checkbox")
	}
	return nil
}

func chooseOption(ctx context.Context, label, option string) error {
	if err := clickFirstText(ctx, label); err != nil {
		return err
	}
	return clickFirstText(ctx, option)
}

func visible(ctx context.Context, selector string) bool {
	script := fmt.Sprintf(`(() => {
  const el = document.querySelector(%q);
  return !!el && (el.offsetWidth > 0 || el.offsetHeight > 0);
})()`, selector)
	var ok bool
	_ = chromedp.Run(ctx, chromedp.Evaluate(script, &ok))
	return ok
}

func totpField(ctx context.Context) string {
	for _, selector := range []string{`input[name="totpPin"]`, `#totpPin`, `input[type="tel"]`} {
		if visible(ctx, selector) {
			return selector
		}
	}
	return ""
}

func totpCode(secret string) (string, error) {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).
		DecodeString(strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(secret)))
	if err != nil {
		return "", fmt.Errorf("decode TOTP secret: %w", err)
	}
	counter := make([]byte, 8)
	binary.BigEndian.PutUint64(counter, uint64(time.Now().Unix()/30))
	mac := hmac.New(sha1.New, key)
	_, _ = mac.Write(counter)
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", value%1_000_000), nil
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

func describePage(ctx context.Context, env map[string]string) error {
	const script = `(() => JSON.stringify({
  url: location.origin + location.pathname,
  text: (document.body ? document.body.innerText : '').slice(0, 1800),
  fields: [...document.querySelectorAll('input,textarea,select')]
    .filter(el => el.offsetWidth > 0 || el.offsetHeight > 0)
    .map(el => [el.tagName, el.type || '', el.name || '', el.placeholder || '', el.getAttribute('aria-label') || ''].join(' | ')),
  controls: [...document.querySelectorAll('a,button,[role=button],[role=tab],[role=radio]')]
    .filter(el => el.offsetWidth > 0 || el.offsetHeight > 0)
    .map(el => (el.textContent || '').trim()).filter(Boolean).slice(0, 80)
}, null, 1))()`
	var description string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &description)); err != nil {
		return err
	}
	for _, value := range env {
		if value != "" {
			description = strings.ReplaceAll(description, value, "<redacted>")
		}
	}
	fmt.Println("--- page ---")
	fmt.Println(description)
	return nil
}
