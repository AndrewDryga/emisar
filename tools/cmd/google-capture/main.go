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
	captureClientName    = "emisar docs capture"
	redactedUser         = "admin@example.com"
	redactedClientID     = "000000000000-example.apps.googleusercontent.com"
	redactedClientSecret = "GOCSPX-example-redacted-client-secret"
)

func main() {
	envPath := flag.String("env", "portal/.agent/secrets/google-workspace.env", "credential env file")
	outDir := flag.String("out", "", "directory for captured PNGs")
	// Google's sign-in does not serve a headless browser: the navigation hangs
	// until the context expires rather than failing, so a headless run reports a
	// deadline with no output at all. Default it off.
	headless := flag.Bool("headless", false, "run Chrome headless (Google sign-in refuses it)")
	cleanupOnly := flag.Bool("cleanup", false, "only delete the OAuth clients past runs created")
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
	if err := run(env, *outDir, *headless, *cleanupOnly); err != nil {
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

func run(env map[string]string, outDir string, headless, cleanupOnly bool) error {
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
	if cleanupOnly {
		// Wait for the console to paint before reaching for its nav — the full flow
		// gets this from authPlatformFlow, and skipping it here left the Clients
		// click hitting nothing.
		if err := waitForText(ctx, "Google Auth Platform", 90*time.Second); err != nil {
			return err
		}
		if err := acceptTerms(ctx); err != nil {
			return err
		}
		return removeCaptureClients(ctx, env, outDir)
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
	if err := acceptTerms(ctx); err != nil {
		return err
	}
	// Two shapes of the same console. A project with nothing configured opens the
	// Get started wizard; one that is already set up opens straight onto the
	// left-nav pages the wizard writes into. Photograph whichever we are given —
	// the wizard is a one-time skin over Branding and Audience.
	if err := waitForText(ctx, "Get started", 20*time.Second); err != nil {
		fmt.Println("  already configured — capturing Branding and Audience directly")
		return configuredFlow(ctx, env, outDir)
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

	return clientFlow(ctx, env, outDir)
}

// clientFlow makes the OAuth client emisar signs in with, and is the same on a
// freshly walked wizard and an already-configured project.
func clientFlow(ctx context.Context, env map[string]string, outDir string) error {
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
	if err := acceptTerms(ctx); err != nil {
		return err
	}
	if err := dismissOverlays(ctx); err != nil {
		return err
	}
	if err := chooseOption(ctx, "Application type", "Web application"); err != nil {
		return err
	}
	if err := fillField(ctx, "Name", captureClientName); err != nil {
		return err
	}
	// Scoped to its own section. The form has TWO "Add URI" buttons — Authorized
	// JavaScript origins comes first — so an unscoped click added the row there and
	// emisar's callback went into the wrong list, which is also why Create never
	// produced a client.
	if err := addURIUnder(ctx, "Authorized redirect URIs", docsRedirectURI); err != nil {
		return err
	}
	// Label-based again: nothing on this console's forms carries an accessible
	// name, so a field lookup binds to nothing. Point at the chosen value and the
	// section the step is about.
	if err := capture(ctx, env, outDir, "google-07-web-application", textHighlight("Web application", "Authorized redirect URIs")); err != nil {
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
	if err := clickFirstText(ctx, "OK"); err != nil {
		return err
	}
	return removeCaptureClients(ctx, env, outDir)
}

// countCaptureClients is how many of this tool's own clients the list still
// shows. Every deletion is judged by this dropping, never by the click landing.
func countCaptureClients(ctx context.Context) (int, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return [...document.querySelectorAll('tr')]
    .filter(tr => visible(tr) && (tr.textContent || '').includes(%q)).length;
})()`, captureClientName)
	var count int
	err := chromedp.Run(ctx, chromedp.Evaluate(script, &count))
	return count, err
}

// removeCaptureClients deletes every OAuth client this tool has ever created in
// the project. A capture run mints a real client with a real secret, so leaving
// it behind adds live credentials to the operator's project on every run — three
// had accumulated before this existed.
func removeCaptureClients(ctx context.Context, env map[string]string, outDir string) error {
	if err := clickExactText(ctx, "Clients"); err != nil {
		return err
	}
	if err := waitForText(ctx, "OAuth 2.0 Client IDs", 45*time.Second); err != nil {
		return err
	}
	for attempt := 0; attempt < 10; attempt++ {
		before, err := countCaptureClients(ctx)
		if err != nil {
			return err
		}
		if before == 0 {
			if attempt == 0 {
				fmt.Println("  no capture clients to remove")
			}
			return nil
		}
		// The row's own trash icon, not a "more" menu — this table puts Delete
		// straight in an Actions column, which is why looking for a menu found
		// nothing and left the clients behind.
		open := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const row = [...document.querySelectorAll('tr')]
    .find(tr => visible(tr) && (tr.textContent || '').includes(%q));
  if (!row) return false;
  const buttons = [...row.querySelectorAll('button,[role=button],a')].filter(visible);
  const trash = buttons.find(el => {
    const name = (el.getAttribute('aria-label') || el.textContent || '').toLowerCase();
    return name.includes('delete') || name.includes('remove');
  }) || buttons[buttons.length - 1];
  if (!trash) return false;
  trash.click();
  return true;
})()`, captureClientName)
		var opened bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(open, &opened)); err != nil {
			return err
		}
		if !opened {
			if attempt == 0 {
				fmt.Println("  no capture clients to remove")
			}
			return nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
			return err
		}
		// Type-to-confirm. The dialog asks for the word DELETE in a Confirmation
		// word field and keeps its Delete button disabled until it is there, so
		// clicking Delete on its own did nothing — ten times over.
		const confirm = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  // By position, not by name. Nothing on this console's forms carries an
  // accessible name, so the field is found as the empty text input that follows
  // the dialog's own instruction.
  const prompt = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').includes('type in this text'))
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  if (!prompt) return false;
  const after = el => (prompt.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  const field = [...document.querySelectorAll('input[type=text],input:not([type])')]
    .find(el => visible(el) && !el.value && after(el));
  if (!field) return false;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(field, 'DELETE');
  field.dispatchEvent(new Event('input', {bubbles: true}));
  field.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
})()`
		var typed bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(confirm, &typed)); err != nil {
			return err
		}
		// Two shapes of this dialog: a credential Google thinks is in use asks for
		// the word DELETE typed in, and a fresh one just asks yes or no. Type when
		// there is a field, and press Delete either way.
		if typed {
			if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
				return err
			}
		}
		// Scoped to the DIALOG. The page's own toolbar carries a disabled "Delete"
		// beside Create client, and an unscoped click kept hitting that one — which
		// is why ten deletions changed nothing.
		const press = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const dialog = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')].find(visible) ||
    [...document.querySelectorAll('*')]
      .filter(el => visible(el) && (el.textContent || '').includes('delete this credential'))
      .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  if (!dialog) return false;
  const button = [...dialog.querySelectorAll('button,[role=button],a')]
    .find(el => visible(el) && !el.disabled && /^delete$/i.test((el.textContent || '').trim()));
  if (!button) return false;
  button.click();
  return true;
})()`
		var pressed bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(press, &pressed)); err != nil {
			return err
		}
		if !pressed {
			_ = screenshot(ctx, outDir, "google-cleanup-no-delete-button")
			return errors.New("the delete dialog has no enabled Delete button")
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(6*time.Second)); err != nil {
			return err
		}
		// Reload before counting. The list does not refresh itself after a delete —
		// the row even keeps a spinner in its Actions cell — so counting the stale
		// table said nothing had happened when it had.
		if err := chromedp.Run(ctx, chromedp.Reload()); err != nil {
			return err
		}
		if err := waitForText(ctx, "OAuth 2.0 Client IDs", 45*time.Second); err != nil {
			return err
		}
		// PROVE it. Printing "removed" straight after the click reported ten
		// deletions of a client that was still there — the same lie every other
		// unverified step in this session told.
		after, err := countCaptureClients(ctx)
		if err != nil {
			return err
		}
		if after >= before {
			_ = screenshot(ctx, outDir, "google-cleanup-stuck")
			_ = describePage(ctx, env)
			return fmt.Errorf("clicked delete but %d capture client(s) remain", after)
		}
		fmt.Printf("  removed a capture client (%d left)\n", after)
	}
	return nil
}

// addURIUnder adds a URI to the named repeating section. Both of this form's URI
// lists render an identical "Add URI" button and an identical unnamed input, so
// the section heading is the only thing that tells them apart: climb from it to
// the block that owns the button, and work inside that.
func addURIUnder(ctx context.Context, section, value string) error {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heading = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  if (!heading) return 'no-section';
  let block = heading;
  for (let up = 0; up < 6 && block.parentElement; up++) {
    const button = [...block.querySelectorAll('button,[role=button]')]
      .find(el => visible(el) && (el.textContent || '').trim() === 'Add URI');
    if (button) {
      button.click();
      return 'added';
    }
    block = block.parentElement;
  }
  return 'no-button';
})()`, section)
	var outcome string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &outcome)); err != nil {
		return err
	}
	if outcome != "added" {
		return fmt.Errorf("adding a URI under %q: %s", section, outcome)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	fill := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const heading = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  if (!heading) return false;
  // Document ORDER, not an ancestor climb. The added row renders in a container
  // the climb from the heading never reached, but the form runs top to bottom:
  // this section's field is the first empty one AFTER its heading, and the other
  // URI list's field is before it.
  const after = el => (heading.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  const field = [...document.querySelectorAll('input[type=text],input:not([type])')]
    .find(el => visible(el) && !el.value && after(el));
  if (!field) return false;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(field, %q);
  field.dispatchEvent(new Event('input', {bubbles: true}));
  field.dispatchEvent(new Event('change', {bubbles: true}));
  field.blur();
  return true;
})()`, section, value)
	var filled bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(fill, &filled)); err != nil {
		return err
	}
	if !filled {
		return fmt.Errorf("no empty URI field appeared under %q", section)
	}
	fmt.Printf("  added a URI under %q\n", section)
	return chromedp.Run(ctx, chromedp.Sleep(1500*time.Millisecond))
}

// dismissOverlays clears the console's own promotional tooltips. One of them
// ("Is this a production environment?") sat over the left nav and the page
// heading in the first captured shot.
func dismissOverlays(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  let closed = 0;
  for (const button of document.querySelectorAll('button,[role=button]')) {
    if (!visible(button)) continue;
    const name = (button.getAttribute('aria-label') || button.textContent || '').trim().toLowerCase();
    if (name === 'close' || name === 'dismiss' || name === 'got it' || name === 'no thanks') {
      button.click();
      closed++;
    }
  }
  return closed;
})()`
	var closed int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &closed)); err != nil {
		return err
	}
	if closed > 0 {
		fmt.Printf("  dismissed %d console overlay(s)\n", closed)
	}
	return chromedp.Run(ctx, chromedp.Sleep(2*time.Second))
}

// acceptTerms clears the Google Cloud Platform / Starter Tier agreement wall
// that fronts a console the account has not agreed on yet. Accepting terms on
// someone's Google account is their decision, so this runs only because the
// account owner asked for it explicitly.
func acceptTerms(ctx context.Context) error {
	// Detect by the VISIBLE button, not by the words. "Terms of Service" appears in
	// the console's own footer links, so matching the body text made this run —
	// and fail — on every page whether the dialog was up or not.
	const present = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return [...document.querySelectorAll('button,[role=button]')]
    .some(el => visible(el) && (el.textContent || '').trim() === 'Agree and continue');
})()`
	var showing bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(present, &showing)); err != nil {
		return err
	}
	if !showing {
		return nil
	}
	// Tick the agreement's OWN checkbox. The dialog carries two — the terms and a
	// marketing opt-in — and a generic "first checkbox" click left Agree and
	// continue disabled, so the dialog stayed up over every screen behind it.
	// Never touch the marketing one.
	const tick = `(() => {
  // Climb, do not use closest(). A Material checkbox's nearest wrapper holds only
  // the box; its label is a SIBLING further up, so requiring the text in the
  // immediate parent never matched and the dialog stayed up over every screen.
  const owns = box => {
    let node = box;
    for (let up = 0; up < 6 && node; up++) {
      if ((node.textContent || '').includes('I agree to the')) return true;
      node = node.parentElement;
    }
    return false;
  };
  const agree = [...document.querySelectorAll('input[type=checkbox]')].find(owns);
  if (!agree) return false;
  if (!agree.checked) {
    agree.click();
    if (!agree.checked) {
      // Some Material builds only respond to the label's own click target.
      const label = agree.id ? document.querySelector('label[for="' + agree.id + '"]') : null;
      if (label) label.click();
    }
  }
  return agree.checked;
})()`
	var ticked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(tick, &ticked)); err != nil {
		return err
	}
	if !ticked {
		// Say so and carry on: the pages behind this dialog still render, and only
		// the create-client panel is actually obscured by it. Failing here would
		// give up screens we can photograph.
		fmt.Println("  terms dialog is up but its agreement box is unreachable; continuing")
		return nil
	}
	if err := clickFirstText(ctx, "Agree and continue", "AGREE AND CONTINUE"); err != nil {
		return err
	}
	fmt.Println("  accepted the Google Cloud terms")
	if err := chromedp.Run(ctx, chromedp.Sleep(8*time.Second)); err != nil {
		return err
	}
	return dismissOverlays(ctx)
}

// configuredFlow captures the Auth Platform pages a project that is already set
// up presents: Branding carries the app name and support email the wizard's App
// Information step writes, Audience carries the Internal/External choice, and
// Clients is where the OAuth client is made. Same fields, reachable pages.
func configuredFlow(ctx context.Context, env map[string]string, outDir string) error {
	if err := clickExactText(ctx, "Branding"); err != nil {
		return err
	}
	if err := waitForText(ctx, "App name", 45*time.Second); err != nil {
		return err
	}
	// Label-based, not field-based: this page's inputs carry no accessible name at
	// all, and the support email is a menu rather than an input, so there is
	// nothing for a field lookup to bind to.
	if err := capture(ctx, env, outDir, "google-01-branding", textHighlight("App name", "User support email")); err != nil {
		return err
	}

	if err := clickExactText(ctx, "Audience"); err != nil {
		return err
	}
	if err := waitForText(ctx, "Internal", 45*time.Second); err != nil {
		return err
	}
	if err := capture(ctx, env, outDir, "google-02-audience", textHighlight("Internal")); err != nil {
		return err
	}

	return clientFlow(ctx, env, outDir)
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
	// Before every shot, not once at the start. The console's welcome dialog
	// arrives on its own schedule — it rendered AFTER the first check and then sat
	// over the create-client form, so "Application type" was never visible. Both
	// calls are no-ops when there is nothing to clear.
	if err := acceptTerms(ctx); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if err := dismissOverlays(ctx); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
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
	// The Branding page shows the tenant's real support address, which is a
	// different value from the sign-in user and was shipping in the shot. Redact
	// any address on the primary domain, then the bare domain itself — longest
	// first, so the address substitution is not pre-empted by the domain one.
	if domain := env["GOOGLE_PRIMARY_DOMAIN"]; domain != "" {
		replacements["help@"+domain] = "help@example.com"
		replacements["support@"+domain] = "support@example.com"
		replacements[domain] = "example.com"
	}
	script := `(() => {
  const replacements = REPLACEMENTS;
  // By PATTERN as well as by value. A capture run creates its OWN OAuth client,
  // whose id and secret are nowhere in the env file, so a value-only swap shipped
  // a live credential in the "client created" shot. Anything SHAPED like a Google
  // client id or secret is redacted whether we have seen it before or not.
  const patterns = [
    [/\b\d{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com\b/gi, CLIENT_ID],
    [/\bGOCSPX-[A-Za-z0-9_-]{6,}\b/g, CLIENT_SECRET]
  ];
  const scrub = value => {
    let out = value;
    for (const [from, to] of replacements) if (from) out = out.split(from).join(to);
    for (const [pattern, to] of patterns) out = out.replace(pattern, to);
    return out;
  };
  const inputSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  const textareaSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
  for (const el of document.querySelectorAll('input,textarea')) {
    const value = scrub(el.value || '');
    if (value !== el.value) (el.tagName === 'TEXTAREA' ? textareaSetter : inputSetter).call(el, value);
  }
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    node.nodeValue = scrub(node.nodeValue || '');
  }
  return true;
})()`
	pairs := make([]string, 0, len(replacements))
	for from, to := range replacements {
		pairs = append(pairs, fmt.Sprintf("[%q,%q]", from, to))
	}
	script = strings.Replace(script, "REPLACEMENTS", "["+strings.Join(pairs, ",")+"]", 1)
	script = strings.Replace(script, "CLIENT_ID", fmt.Sprintf("%q", redactedClientID), 1)
	script = strings.Replace(script, "CLIENT_SECRET", fmt.Sprintf("%q", redactedClientSecret), 1)
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
	// SET the value, do not type into it. The console pre-fills Name with "Web
	// client 3", and both typing on top and chromedp.Clear left that prefix in
	// place — "Web client 3emisar docs capture" shipped in a shot.
	set := fmt.Sprintf(`(() => {
  const result = document.evaluate(%q, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
  const field = result.singleNodeValue;
  if (!field) return false;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(field, %q);
  field.dispatchEvent(new Event('input', {bubbles: true}));
  field.dispatchEvent(new Event('change', {bubbles: true}));
  return field.value === %q;
})()`, selector, value, value)
	var ok bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(set, &ok)); err != nil {
		return err
	}
	if ok {
		return chromedp.Run(ctx, chromedp.Sleep(time.Second))
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

// chooseOption drives a Material select: open the field whose label STARTS WITH
// the given text, then pick the option out of the popup. Exact-matching the label
// never worked here — the console renders a required field as "Application type *"
// and swaps in the chosen value once one is picked — and the trigger is a
// combobox, not one of the anchors and buttons clickFirstText searches.
func chooseOption(ctx context.Context, label, option string) error {
	open := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const label = %q;
  // A real <select> needs no popup at all.
  for (const select of document.querySelectorAll('select')) {
    if (!visible(select)) continue;
    const owner = select.closest('div,label');
    if (owner && (owner.textContent || '').includes(label)) {
      const match = [...select.options].find(o => o.textContent.trim() === %q);
      if (match) {
        select.value = match.value;
        select.dispatchEvent(new Event('change', {bubbles: true}));
        return 'set';
      }
    }
  }
  const triggers = [...document.querySelectorAll('[role=combobox],[aria-haspopup],[role=button],button,div')]
    .filter(el => visible(el) && (el.textContent || '').trim().startsWith(label))
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  if (!triggers.length) return '';
  triggers[0].scrollIntoView({block: 'center'});
  triggers[0].click();
  return 'opened';
})()`, label, option)
	var outcome string
	if err := chromedp.Run(ctx, chromedp.Evaluate(open, &outcome)); err != nil {
		return err
	}
	switch outcome {
	case "":
		return fmt.Errorf("no field labelled %q to open", label)
	case "set":
		fmt.Printf("  chose %q for %q\n", option, label)
		return chromedp.Run(ctx, chromedp.Sleep(2*time.Second))
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(1500*time.Millisecond)); err != nil {
		return err
	}
	pick := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const options = [...document.querySelectorAll('[role=option],li,[role=menuitem]')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  if (!options.length) return false;
  options[0].click();
  return true;
})()`, option)
	var picked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(pick, &picked)); err != nil {
		return err
	}
	if !picked {
		return fmt.Errorf("%q is open but has no option %q", label, option)
	}
	fmt.Printf("  chose %q for %q\n", option, label)
	return chromedp.Run(ctx, chromedp.Sleep(2*time.Second))
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
