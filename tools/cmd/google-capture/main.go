// Command google-capture drives a live Google Cloud console and photographs
// the Google Auth Platform setup path for the Google Workspace SSO guide.
//
// Reads GOOGLE_* from portal/.agent/secrets/google-workspace.env (gitignored).
// DEV ONLY, and it lives in the never-shipped tools module.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/chromedp/cdproto/network"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/idpcapture"
	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/chromedp"

	capturekit "github.com/andrewdryga/emisar/tools/internal/capture"
)

const (
	consoleURL           = "https://console.cloud.google.com/auth/overview"
	docsRedirectURI      = "https://emisar.dev/sign_in/sso/callback"
	captureClientName    = "emisar docs capture"
	certifyClientName    = "emisar login certification"
	redactedUser         = "admin@example.com"
	redactedClientID     = "000000000000-example.apps.googleusercontent.com"
	redactedClientSecret = "GOCSPX-example-redacted-client-secret"
)

var (
	googleClientIDPattern     = regexp.MustCompile(`[0-9]{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com`)
	googleClientSecretPattern = regexp.MustCompile(`GOCSPX-[A-Za-z0-9_-]{6,}`)
)

func main() {
	envPath := flag.String("env", "portal/.agent/secrets/google-workspace.env", "credential env file")
	outDir := flag.String("out", "", "directory for captured PNGs")
	// Google's sign-in does not serve a headless browser: the navigation hangs
	// until the context expires rather than failing, so a headless run reports a
	// deadline with no output at all. Default it off.
	headless := flag.Bool("headless", false, "run Chrome headless (Google sign-in refuses it)")
	cleanupOnly := flag.Bool("cleanup", false, "only delete the OAuth clients past runs created")
	// The Get started wizard is the ONLY place Audience is a choice. On a project
	// that already has it, the console shows the settings page it wrote — which is
	// what shipped, and it does not show the reader the decision they have to make.
	// A fresh project is the only way to photograph the real step.
	freshProject := flag.String("fresh-project", "", "create this project first and walk its Get started wizard")
	project := flag.String("project", "", "capture against this project id instead of the credential's own project")
	certifyRedirect := flag.String("certify-redirect-uri", "", "create a client for this redirect URI and write its credentials to portal/.agent/secrets/google-cert-client.env")
	certifyCredentials := flag.String("certify-credentials", "portal/.agent/secrets/google-cert-client.env", "ignored env file for the certification client's credentials")
	certifyLogin := flag.String("certify-login", "", "drive a real OIDC sign-in through this emisar begin URL and report where it lands")
	deleteProjects := flag.String("delete-projects", "", "comma-separated project ids to shut down, then exit")
	listProjects := flag.Bool("list-projects", false, "print the account's projects and whether each has an auth config")
	// Agreeing to Google Cloud's terms binds the ACCOUNT, not the run, so it is
	// never implied by asking for screenshots. The account owner asks for it here,
	// explicitly, or the capture stops at the wall.
	acceptCloudTOS := flag.Bool("accept-cloud-tos", false, "agree to the Google Cloud Terms of Service on this account")
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
	if err := run(env, *outDir, *headless, *cleanupOnly, *freshProject, *listProjects, *acceptCloudTOS, *project, *deleteProjects, *certifyRedirect, *certifyCredentials, *certifyLogin); err != nil {
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

func run(env map[string]string, outDir string, headless, cleanupOnly bool, freshProject string, listProjects, acceptCloudTOS bool, project, deleteProjects, certifyRedirect, certifyCredentials, certifyLogin string) error {
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

	// Pin the console to its light theme. It follows prefers-color-scheme, so a run
	// started while the machine is in dark mode produces shots that match nothing
	// else in the guide.
	if err := chromedp.Run(ctx, emulation.SetEmulatedMedia().WithFeatures([]*emulation.MediaFeature{
		{Name: "prefers-color-scheme", Value: "light"},
	})); err != nil {
		return err
	}

	projectNumber := strings.SplitN(env["GOOGLE_CLIENT_ID"], "-", 2)[0]
	if project != "" {
		projectNumber = project
	}
	entry := consoleURL + "?project=" + projectNumber + "&hl=en"
	if freshProject != "" {
		entry = "https://console.cloud.google.com/projectcreate?hl=en"
	}
	if err := chromedp.Run(ctx, chromedp.Navigate(entry), chromedp.Sleep(3*time.Second)); err != nil {
		return err
	}
	if err := signIn(ctx, env, acceptCloudTOS); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "google-failed")
		_ = describePage(ctx, env)
		return err
	}
	if listProjects {
		return printProjects(ctx)
	}
	if deleteProjects != "" {
		for _, id := range strings.Split(deleteProjects, ",") {
			id = strings.TrimSpace(id)
			if id == "" {
				continue
			}
			if err := shutDownProject(ctx, id); err != nil {
				return fmt.Errorf("%s: %w", id, err)
			}
		}
		return nil
	}
	if freshProject != "" {
		if err := createProject(ctx, freshProject, outDir); err != nil {
			_ = idpcapture.Screenshot(ctx, outDir, "google-failed")
			_ = describePage(ctx, env)
			return err
		}
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
	if certifyLogin != "" {
		return certifyLoginFlow(ctx, env, outDir, certifyLogin)
	}
	if certifyRedirect != "" {
		if err := certifyClientFlow(ctx, env, outDir, certifyRedirect, certifyCredentials); err != nil {
			_ = idpcapture.Screenshot(ctx, outDir, "google-failed")
			_ = describePage(ctx, env)
			return err
		}
		return nil
	}
	if err := authPlatformFlow(ctx, env, outDir); err != nil {
		_ = idpcapture.Screenshot(ctx, outDir, "google-failed")
		_ = describePage(ctx, env)
		return err
	}
	return nil
}

// createProject makes the throwaway project whose Get started wizard the capture
// walks, then enters the Auth Platform on it. The project id Google derives from
// the name is what the platform URL needs, and it is not the name — so it is read
// back off the console rather than guessed.
// printProjects lists what the account can reach, so a capture that needs an
// unconfigured project can be pointed at one that already exists instead of
// creating another.
// agreeToCloudTerms clears the free-trial signup wall an account that has never
// used Google Cloud lands on. Only reachable behind -accept-cloud-tos.
//
// This is the FULL-PAGE wall, not the in-console dialog acceptTerms handles: its
// button carries an ampersand ("Agree & continue") and it sits behind a country
// selector that must already hold a value.
func agreeToCloudTerms(ctx context.Context) error {
	const tick = `(() => {
  let ticked = 0;
  for (const box of document.querySelectorAll('input[type=checkbox]')) {
    let node = box, wanted = false;
    for (let up = 0; up < 6 && node; up++) {
      const text = node.textContent || '';
      if (/Terms of Service|I agree/i.test(text)) { wanted = true; break; }
      node = node.parentElement;
    }
    // Never the marketing opt-in.
    if (!wanted) continue;
    if ((node.textContent || '').match(/updates|announcements|offers|newsletter/i)) continue;
    if (!box.checked) { box.click(); }
    if (box.checked) ticked++;
  }
  return ticked;
})()`
	var ticked int
	if err := chromedp.Run(ctx, chromedp.Evaluate(tick, &ticked)); err != nil {
		return err
	}
	fmt.Printf("  ticked %d terms checkbox(es)\n", ticked)
	if err := clickFirstText(ctx, "Agree & continue", "Agree and continue", "AGREE & CONTINUE"); err != nil {
		return err
	}
	fmt.Println("  agreed to the Google Cloud terms")
	return chromedp.Run(ctx, chromedp.Sleep(10*time.Second))
}

// shutDownProject retires a project this tool created. The wizard capture needs a
// project with nothing configured, and a project can only be walked through it
// once, so each run leaves one behind.
//
// Google gates the shutdown behind typing the project id back, which is also the
// check that this deletes the intended project and not whichever one the console
// happened to have open.
func shutDownProject(ctx context.Context, id string) error {
	settings := "https://console.cloud.google.com/iam-admin/settings?project=" + id + "&hl=en"
	if err := chromedp.Run(ctx, chromedp.Navigate(settings), chromedp.Sleep(12*time.Second)); err != nil {
		return err
	}
	if err := dismissOverlays(ctx); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Shut down", "SHUT DOWN"); err != nil {
		return fmt.Errorf("no shut down control: %w", err)
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(5*time.Second)); err != nil {
		return err
	}
	// Type the id into the confirmation field the dialog puts up.
	confirm := fmt.Sprintf(`(() => {
  const wanted = %q;
  const inputs = [...document.querySelectorAll('input')]
    .filter(el => (el.offsetWidth > 0 || el.offsetHeight > 0) && el.type === 'text');
  if (!inputs.length) return '';
  const input = inputs[inputs.length - 1];
  if (!input.id) input.id = 'emisar-confirm-shutdown';
  return '#' + input.id + '|' + wanted;
})()`, id)
	var handle string
	if err := chromedp.Run(ctx, chromedp.Evaluate(confirm, &handle)); err != nil {
		return err
	}
	if handle == "" {
		return errors.New("the shutdown dialog has no confirmation field")
	}
	selector := strings.SplitN(handle, "|", 2)[0]
	if err := typeRealKeys(ctx, selector, id); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Shut down anyway", "SHUT DOWN ANYWAY", "Shut down"); err != nil {
		return err
	}
	fmt.Printf("  shut down %s\n", id)
	return chromedp.Run(ctx, chromedp.Sleep(8*time.Second))
}

func printProjects(ctx context.Context) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://console.cloud.google.com/cloud-resource-manager?hl=en"),
		chromedp.Sleep(15*time.Second)); err != nil {
		return err
	}
	var body string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
		return err
	}
	fmt.Println("--- resource manager ---")
	fmt.Println(body)
	return nil
}

func createProject(ctx context.Context, name, outDir string) error {
	if err := waitForText(ctx, "Project name", 90*time.Second); err != nil {
		return fmt.Errorf("the project-create form never appeared: %w", err)
	}
	// By position, not by label: the create form's name input has no label,
	// placeholder or aria-label of its own — the visible "Project name" text is a
	// sibling node — so the label-driven filler finds nothing to type into.
	const nameSelector = `(() => {
  // el.type, not the [type=text] selector: these inputs carry no type ATTRIBUTE,
  // so the attribute selector matches none of them while the DOM property still
  // reports "text".
  const inputs = [...document.querySelectorAll('input')]
    .filter(el => (el.offsetWidth > 0 || el.offsetHeight > 0) && el.type === 'text');
  if (!inputs.length) return '';
  const input = inputs[0];
  if (!input.id) input.id = 'emisar-project-name';
  return '#' + input.id;
})()`
	var selector string
	if err := chromedp.Run(ctx, chromedp.Evaluate(nameSelector, &selector)); err != nil {
		return err
	}
	if selector == "" {
		return errors.New("the project-create form has no name input")
	}
	if err := typeRealKeys(ctx, selector, name); err != nil {
		return err
	}
	// Google shows the derived id under the field as "Project ID: <id>". Read it
	// before submitting; afterwards the form is gone.
	const idScript = `(() => {
  const match = document.body.innerText.match(/Project ID:\s*([a-z0-9-]+)/);
  return match ? match[1] : '';
})()`
	var projectID string
	if err := chromedp.Run(ctx, chromedp.Evaluate(idScript, &projectID)); err != nil {
		return err
	}
	if projectID == "" {
		return errors.New("the create form never showed the derived project id")
	}
	fmt.Printf("  creating project %s\n", projectID)
	if err := clickFirstText(ctx, "Create"); err != nil {
		return err
	}
	// Creation is asynchronous and the console does not block on it. Poll the
	// platform URL until it answers with the wizard rather than a permission error.
	platform := consoleURL + "?project=" + projectID + "&hl=en"
	deadline := time.Now().Add(4 * time.Minute)
	for {
		if time.Now().After(deadline) {
			_ = idpcapture.Screenshot(ctx, outDir, "google-project-never-ready")
			return fmt.Errorf("project %s never became usable", projectID)
		}
		if err := chromedp.Run(ctx, chromedp.Navigate(platform), chromedp.Sleep(8*time.Second)); err != nil {
			return err
		}
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, "Google Auth Platform") && !strings.Contains(body, "do not have permission") {
			fmt.Printf("  project %s is ready\n", projectID)
			return nil
		}
	}
}

func signIn(ctx context.Context, env map[string]string, acceptCloudTOS bool) error {
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
		// Probed once, up front, so a page we cannot read aborts the loop
		// instead of falling through every branch as "nothing is on screen".
		identifierShown, err := visible(ctx, `#identifierId`)
		if err != nil {
			return err
		}
		passwordShown, err := visible(ctx, `input[name="Passwd"]`)
		if err != nil {
			return err
		}
		totp, err := totpField(ctx)
		if err != nil {
			return err
		}

		switch {
		case strings.Contains(location, "accounts.google.com") && identifierShown && !submittedUser:
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

		case strings.Contains(location, "accounts.google.com") && passwordShown && !submittedPassword:
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

		case strings.Contains(location, "accounts.google.com") && totp != "" && !submittedTOTP:
			if env["GOOGLE_TEST_TOTP_SECRET"] == "" {
				return errors.New("an authenticator code was requested but GOOGLE_TEST_TOTP_SECRET is empty")
			}
			if remaining := 30 - time.Now().Unix()%30; remaining < 8 {
				if err := chromedp.Run(ctx, chromedp.Sleep(time.Duration(remaining+1)*time.Second)); err != nil {
					return err
				}
			}
			code, err := capturekit.TOTPCode(env["GOOGLE_TEST_TOTP_SECRET"])
			if err != nil {
				return err
			}
			if err := typeRealKeys(ctx, totp, code); err != nil {
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
				if !acceptCloudTOS {
					return errors.New("accepting the Google Cloud Terms of Service is a human account-level decision; re-run with -accept-cloud-tos if it is yours to give")
				}
				if err := agreeToCloudTerms(ctx); err != nil {
					return err
				}
				continue
			}
			if strings.Contains(body, "Google Auth Platform") || strings.Contains(body, "Welcome") ||
				strings.Contains(body, "Select a project") || strings.Contains(body, "New Project") {
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
	// Three shapes, not two. A project with the platform configured opens on the
	// settings pages; an unconfigured one opens either on a Get started button or
	// straight onto the numbered stepper, depending on how the console routed in.
	// Capitalization is Google's: the step is "App Information".
	inWizard := waitForText(ctx, "App Information", 20*time.Second) == nil
	if !inWizard {
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
		if err := waitForText(ctx, "App Information", 30*time.Second); err != nil {
			return err
		}
	}
	if err := fillField(ctx, "App name", "emisar"); err != nil {
		return err
	}
	// A Material select, not a text field and not a plain link: the support email is
	// picked from the accounts Google already knows, so it is driven the same way as
	// the other dropdowns in this console.
	if err := chooseOption(ctx, "User support email", env["GOOGLE_TEST_USER"]); err != nil {
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
	// The agreement checkbox is not in every version of this wizard — the current
	// one ends on Create alone. Highlight whichever control the reader actually has
	// to act on rather than failing on the one that is missing.
	marker := textHighlight("Create")
	if err := selectCheckbox(ctx); err == nil {
		marker = textHighlight("I agree")
	} else {
		fmt.Println("  the Finish step has no agreement checkbox; highlighting Create")
	}
	if err := capture(ctx, env, outDir, "google-05-finish", marker); err != nil {
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
// certifyLoginFlow drives a real Google Workspace sign-in through emisar and
// reports where it lands. This is the claim the guide makes — that a Workspace
// member can sign in to emisar with Google — and console screenshots do not
// prove it. Only completing the round trip does.
func certifyLoginFlow(ctx context.Context, env map[string]string, outDir, beginURL string) error {
	// Ask emisar for the authorization URL it would send the operator to, then add
	// a login hint so Google can skip its account chooser. That chooser renders in
	// a frame this driver cannot read — document text is a spinner while the page
	// is fully painted — and hinting the account is both simpler and closer to what
	// a returning operator actually sees.
	//
	// Only the hint and the language are added; the state, nonce and PKCE challenge
	// are emisar's own, so what Google validates is what emisar issued.
	// Start the sign-in with a client that does NOT follow the redirect, so the
	// authorization URL can be read before Google turns it into an account-chooser
	// URL — hinting the chooser does nothing, which is what left this looping.
	//
	// The session it creates carries the state, nonce and PKCE verifier, so it has
	// to end up in the BROWSER: emisar stores it in a cookie, and the callback is
	// answered by the browser. Copy it across rather than running the two halves in
	// different cookie jars, which is what made emisar refuse a callback for a
	// sign-in that browser had never begun.
	authorizeURL, session, err := beginSignIn(beginURL)
	if err != nil {
		return err
	}
	begin, err := url.Parse(beginURL)
	if err != nil || begin.Scheme == "" || begin.Host == "" {
		return errors.New("the emisar begin URL has no origin")
	}
	emisarOrigin := begin.Scheme + "://" + begin.Host

	if err := chromedp.Run(ctx, chromedp.Navigate(emisarOrigin+"/sign_in")); err != nil {
		return err
	}
	if err := chromedp.Run(ctx, network.SetCookie(sessionCookieName, session).
		WithURL(emisarOrigin+"/").WithPath("/")); err != nil {
		return err
	}

	// Re-enter the SAME authorization request with the account hinted, so Google
	// skips its chooser. Only the hint and language are added; the state, nonce and
	// PKCE challenge are emisar's own.
	hinted := authorizeURL + "&login_hint=" + url.QueryEscape(env["GOOGLE_TEST_USER"]) + "&hl=en"

	if err := chromedp.Run(ctx,
		chromedp.Navigate(hinted),
		chromedp.Sleep(12*time.Second)); err != nil {
		return err
	}

	// Google may ask to pick an account or to confirm consent the first time. Wait
	// for each screen to actually paint — reading it mid-load returned a spinner
	// ("Загрузка…"; this account's locale is not English), so every click landed on
	// nothing and the loop spun through its attempts against a loading page.
	for attempt := 0; attempt < 6; attempt++ {
		var location string
		if err := chromedp.Run(ctx, chromedp.Location(&location)); err != nil {
			return err
		}
		if !strings.Contains(location, "accounts.google.com") {
			break
		}

		body, err := waitForPaint(ctx)
		if err != nil {
			return err
		}
		fmt.Printf("  at Google: %s\n", firstLine(redactGoogleText(body, env)))

		// The account first, then whatever advances the screen. Match by position
		// rather than by label: the buttons are localized.
		advanced := false

		for _, label := range []string{"Continue", "Allow", "Next", env["GOOGLE_TEST_USER"]} {
			clicked, err := clickDeepAt(ctx, label)
			if err != nil {
				return err
			}
			if clicked {
				if label == env["GOOGLE_TEST_USER"] {
					fmt.Println("  clicked the certification account")
				} else {
					fmt.Printf("  clicked %q\n", label)
				}
				advanced = true
				break
			}
		}

		if !advanced {
			_ = clickPrimaryButton(ctx)
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(10*time.Second)); err != nil {
			return err
		}
	}

	var location, body string
	if err := chromedp.Run(ctx,
		chromedp.Location(&location),
		chromedp.Evaluate(deepTextScript, &body)); err != nil {
		return err
	}
	_ = idpcapture.Screenshot(ctx, outDir, "google-certify-login")
	fmt.Printf("  landed on %s\n", routeOnly(location))
	fmt.Printf("  page says: %s\n", firstLine(redactGoogleText(body, env)))

	if strings.Contains(location, "/sign_in") {
		return fmt.Errorf("sign-in did not complete — still on %s", routeOnly(location))
	}
	return nil
}

func routeOnly(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "<invalid route>"
	}
	return parsed.Path
}

// deepText collects text across open SHADOW ROOTS. Google's sign-in screens keep
// their content in web components, so document.body.innerText is just the loading
// placeholder while the page is fully painted — which made every wait time out
// and every click land on nothing.
const deepTextScript = `(() => {
  const out = [];
  const walk = root => {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) walk(el.shadowRoot);
      // Same-origin iframes too: Google renders sign-in inside one, so the top
      // document is only ever the loading placeholder.
      if (el.tagName === 'IFRAME') {
        try { if (el.contentDocument) walk(el.contentDocument); } catch (e) {}
      }
    }
    const text = root.body ? root.body.innerText : (root.textContent || '');
    if (text) out.push(text);
  };
  walk(document);
  return out.join('\n');
})()`

// clickDeepAt finds text across open shadow roots and clicks its centre with a
// real mouse event, because these controls do not respond to a synthetic click on
// the text node itself.
func clickDeepAt(ctx context.Context, wanted string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const target = %q;
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hits = [];
  const walk = (root, offsetX, offsetY) => {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) walk(el.shadowRoot, offsetX, offsetY);
      if (el.tagName === 'IFRAME') {
        try {
          if (el.contentDocument) {
            // A rect inside a frame is relative to that frame, so carry its origin.
            const f = el.getBoundingClientRect();
            walk(el.contentDocument, offsetX + f.left, offsetY + f.top);
          }
        } catch (e) {}
      }
      if (!visible(el)) continue;
      if (el.querySelector('*')) continue;
      if (!(el.textContent || '').includes(target)) continue;
      const box = el.getBoundingClientRect();
      hits.push({x: box.left + box.width / 2 + offsetX, y: box.top + box.height / 2 + offsetY});
    }
  };
  walk(document, 0, 0);
  if (!hits.length) return '';
  return JSON.stringify({x: Math.round(hits[0].x), y: Math.round(hits[0].y)});
})()`, wanted)

	var found string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &found)); err != nil {
		return false, err
	}
	if found == "" {
		return false, nil
	}

	var at struct{ X, Y float64 }
	if err := json.Unmarshal([]byte(found), &at); err != nil {
		return false, err
	}
	return true, chromedp.Run(ctx, chromedp.MouseClickXY(at.X, at.Y))
}

const sessionCookieName = "_emisar_web_key"

// beginSignIn asks emisar to start a sign-in and returns both where it points the
// operator and the session cookie holding that request's state, nonce and PKCE
// verifier.
func beginSignIn(beginURL string) (string, string, error) {
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	response, err := client.Get(beginURL)
	if err != nil {
		return "", "", err
	}
	defer response.Body.Close()

	location := response.Header.Get("Location")
	if !strings.Contains(location, "accounts.google.com") {
		return "", "", fmt.Errorf("emisar did not start a Google sign-in (status %d)", response.StatusCode)
	}

	for _, cookie := range response.Cookies() {
		if cookie.Name == sessionCookieName {
			return location, cookie.Value, nil
		}
	}
	return "", "", errors.New("emisar's sign-in response carried no session cookie")
}

// waitForPaint returns the page's text once it stops being a loading placeholder.
func waitForPaint(ctx context.Context) (string, error) {
	deadline := time.Now().Add(45 * time.Second)

	for {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(deepTextScript, &body)); err != nil {
			return "", err
		}
		trimmed := strings.TrimSpace(body)
		loading := trimmed == "" || strings.HasPrefix(trimmed, "Загрузка") || strings.HasPrefix(trimmed, "Loading")
		if !loading || time.Now().After(deadline) {
			return body, nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
			return "", err
		}
	}
}

// clickPrimaryButton presses the last enabled button on the screen, which on
// Google's consent and chooser screens is the one that advances. Their labels are
// localized, so matching text is not reliable here.
func clickPrimaryButton(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const buttons = [...document.querySelectorAll('button,[role=button]')]
    .filter(el => visible(el) && !el.disabled && (el.textContent || '').trim());
  if (!buttons.length) return false;
  buttons[buttons.length - 1].click();
  return true;
})()`
	var clicked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &clicked)); err != nil {
		return err
	}
	// The script's own answer was discarded, so "this page has no enabled
	// button" was indistinguishable from a click.
	if !clicked {
		return errors.New("the page offered no enabled primary button")
	}
	return nil
}

func firstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			if len(trimmed) > 90 {
				return trimmed[:90]
			}
			return trimmed
		}
	}
	return ""
}

// certifyClientFlow makes an OAuth client pointed at a LOCAL portal, so a real
// sign-in can be driven end to end. Google exempts http://localhost from its
// https rule for exactly this, which is why no tunnel is needed.
//
// The credentials are written to the secrets directory rather than printed: they
// are live, and a transcript is not where a client secret should live.
func certifyClientFlow(ctx context.Context, env map[string]string, outDir, redirectURI, credentialsPath string) error {
	if err := waitForText(ctx, "Google Auth Platform", 90*time.Second); err != nil {
		return err
	}
	if err := acceptTerms(ctx); err != nil {
		return err
	}
	if err := clickExactText(ctx, "Clients"); err != nil {
		return err
	}
	if err := waitForText(ctx, "OAuth 2.0 Client IDs", 45*time.Second); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Create client", "Create credentials"); err != nil {
		return err
	}
	if err := waitForText(ctx, "Create OAuth client ID", 30*time.Second); err != nil {
		return err
	}
	if err := chooseOption(ctx, "Application type", "Web application"); err != nil {
		return err
	}
	if err := fillField(ctx, "Name", certifyClientName); err != nil {
		return err
	}
	if err := addURIUnder(ctx, "Authorized redirect URIs", redirectURI); err != nil {
		return err
	}
	if err := clickFirstText(ctx, "Create"); err != nil {
		return err
	}
	if err := waitForText(ctx, "OAuth client created", 45*time.Second); err != nil {
		return err
	}

	const readCredentials = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const inputs = [...document.querySelectorAll('input')].filter(visible).map(el => el.value).filter(Boolean);
  const text = document.body.innerText;
  const id = (text.match(/[0-9]{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com/) || [])[0] ||
    inputs.find(v => /\.apps\.googleusercontent\.com$/.test(v)) || '';
  const secret = (text.match(/GOCSPX-[A-Za-z0-9_-]{6,}/) || [])[0] ||
    inputs.find(v => /^GOCSPX-/.test(v)) || '';
  return id + '\n' + secret;
})()`
	var credentials string
	if err := chromedp.Run(ctx, chromedp.Evaluate(readCredentials, &credentials)); err != nil {
		return err
	}
	parts := strings.SplitN(strings.TrimSpace(credentials), "\n", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return errors.New("the created-client dialog did not yield both a client id and secret")
	}

	body := fmt.Sprintf("# emisar OIDC login certification client — redirect %s\nGOOGLE_CERT_CLIENT_ID=%s\nGOOGLE_CERT_CLIENT_SECRET=%s\n", redirectURI, parts[0], parts[1])
	if err := os.WriteFile(credentialsPath, []byte(body), 0o600); err != nil {
		return err
	}
	fmt.Printf("  wrote %s (client %s…)\n", credentialsPath, parts[0][:12])
	return nil
}

func countCaptureClients(ctx context.Context) (int, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const ours = tr => [%q, %q].some(name => (tr.textContent || '').includes(name));
  return [...document.querySelectorAll('tr')].filter(tr => visible(tr) && ours(tr)).length;
})()`, captureClientName, certifyClientName)
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
		selectRow := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const ours = tr => [%q, %q].some(name => (tr.textContent || '').includes(name));
  const row = [...document.querySelectorAll('tr')].find(tr => visible(tr) && ours(tr));
  if (!row) return false;
  const box = row.querySelector('input[type=checkbox],[role=checkbox]');
  if (!box) return false;
  box.click();
  return true;
})()`, captureClientName, certifyClientName)
		var selected bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(selectRow, &selected)); err != nil {
			return err
		}
		if !selected {
			// countCaptureClients already said before > 0, so the rows are there
			// and the checkbox selector missed them. Reporting "no capture
			// clients to remove" here told an operator their project was clean
			// while live OAuth secrets sat in it — the exact thing
			// shared-capture-rigs-own-what-they-create forbids.
			_ = idpcapture.Screenshot(ctx, outDir, "google-cleanup-unselectable")
			_ = describePage(ctx, env)
			return fmt.Errorf("%d client(s) match this rig's names but no row checkbox could be selected", before)
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
			return err
		}
		const openDelete = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const button = [...document.querySelectorAll('button,[role=button],a')]
    .find(el => visible(el) && !el.disabled && /^delete$/i.test((el.textContent || '').trim()));
  if (!button) return false;
  button.click();
  return true;
})()`
		var opened bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(openDelete, &opened)); err != nil {
			return err
		}
		if !opened {
			return errors.New("the selected capture client did not enable the Delete action")
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
  const dialog = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')]
      .find(el => visible(el) && /delete this credential/i.test(el.textContent || '')) ||
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
			_ = idpcapture.Screenshot(ctx, outDir, "google-cleanup-no-delete-button")
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
			_ = idpcapture.Screenshot(ctx, outDir, "google-cleanup-stuck")
			_ = describePage(ctx, env)
			return fmt.Errorf("clicked delete but %d capture client(s) remain", after)
		}
		fmt.Printf("  removed a capture client (%d left)\n", after)
	}
	// The loop is capped, so exhausting it is not success: say what is left
	// rather than returning a silent all-clear over live credentials.
	remaining, err := countCaptureClients(ctx)
	if err != nil {
		return err
	}
	if remaining > 0 {
		return fmt.Errorf("gave up after 10 delete attempts with %d client(s) still present", remaining)
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
// expandNav opens the Google Auth Platform's left navigation when the console
// has it collapsed. The console decides that from the window width and its own
// stored preference, and when it collapses, the nav's column stays in the layout
// — so a shot came out with a blank 285px gutter down the left and no way for a
// reader to see where in the product the step happens.
func expandNav(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  // Already open: the nav lists the platform's own pages.
  const open = [...document.querySelectorAll('a,[role=link],[role=treeitem]')]
    .some(el => visible(el) && ['Clients', 'Audience', 'Branding'].includes((el.textContent || '').trim()));
  if (open) return 0;
  const toggle = [...document.querySelectorAll('button,[role=button]')]
    .find(el => {
      if (!visible(el)) return false;
      const name = (el.getAttribute('aria-label') || el.title || '').trim().toLowerCase();
      return name.includes('expand nav') || name.includes('show nav') || name === 'expand';
    });
  if (!toggle) return -1;
  toggle.click();
  return 1;
})()`
	var result int
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &result)); err != nil {
		return err
	}
	if result == -1 {
		return errors.New("the left nav is collapsed and has no expand control")
	}
	if result == 1 {
		fmt.Println("  expanded the left nav")
		return chromedp.Run(ctx, chromedp.Sleep(1500*time.Millisecond))
	}
	return nil
}

func dismissOverlays(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  let closed = 0;
  // The free-trial promo strip does not go away when its Dismiss is clicked — the
  // console re-renders it — so it is removed outright. It is transient sales chrome
  // over the console, not part of any step, and it sat across the top of every shot.
  for (const node of document.querySelectorAll('div,section,aside')) {
    if (!visible(node)) continue;
    const text = (node.textContent || '').trim();
    if (!text.startsWith('Start your Free Trial with $300 in credit')) continue;
    if (text.length > 200) continue;
    node.remove();
    closed++;
    break;
  }
  // Anchors too: the free-trial promo banner's Dismiss is a link, so a
  // button-only sweep left it across the top of every shot. Match on the EXACT
  // name — "Start free" sits beside it and starts a billing signup.
  for (const button of document.querySelectorAll('button,[role=button],a')) {
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
  const targets = [];
  let marked = 0;
  // Frame every ringed control, not just the last one. Centering each in turn left
  // the reader looking at a form whose first outlined field was cut off the top of
  // the shot, which is the one they act on first.
  const frame = found => {
    if (!found.length) return;
    const tops = found.map(el => el.getBoundingClientRect().top + window.scrollY);
    const bottoms = found.map(el => el.getBoundingClientRect().bottom + window.scrollY);
    const top = Math.min(...tops), bottom = Math.max(...bottoms);
    const margin = 140;
    if (bottom - top + margin * 2 <= window.innerHeight) {
      window.scrollTo({top: Math.max(0, (top + bottom) / 2 - window.innerHeight / 2)});
    } else {
      window.scrollTo({top: Math.max(0, top - margin)});
    }
  };
  for (const label of labels) {
    const matches = [...document.querySelectorAll('a,button,label,span,div,li,td,[role=button],[role=radio]')]
      .filter(el => visible(el) && (el.textContent || '').includes(label));
    if (!matches.length) continue;
    matches.sort((a, b) => a.textContent.length - b.textContent.length);
    const target = matches[0].closest('label,a,button,tr,li,[role=radio]') || matches[0];
    target.style.outline = '3px solid #10b981';
    target.style.outlineOffset = '3px';
    target.style.borderRadius = '6px';
    targets.push(target);
    marked++;
  }
  frame(targets);
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
  const targets = [];
  let marked = 0;
  // Frame every ringed control, not just the last one. Centering each in turn left
  // the reader looking at a form whose first outlined field was cut off the top of
  // the shot, which is the one they act on first.
  const frame = found => {
    if (!found.length) return;
    const tops = found.map(el => el.getBoundingClientRect().top + window.scrollY);
    const bottoms = found.map(el => el.getBoundingClientRect().bottom + window.scrollY);
    const top = Math.min(...tops), bottom = Math.max(...bottoms);
    const margin = 140;
    if (bottom - top + margin * 2 <= window.innerHeight) {
      window.scrollTo({top: Math.max(0, (top + bottom) / 2 - window.innerHeight / 2)});
    } else {
      window.scrollTo({top: Math.max(0, top - margin)});
    }
  };
  for (const wanted of labels) {
    const controls = [...document.querySelectorAll('input,textarea,select,[role=combobox]')].filter(visible);
    const control = controls.find(el => {
      const text = [
        el.getAttribute('aria-label') || '', el.placeholder || '', el.name || '', el.id || '',
        ...(el.labels ? [...el.labels].map(label => label.textContent || '') : [])
      ].join(' ').toLowerCase();
      return text.includes(wanted);
    });
    // A Material select carries no aria-label, placeholder, name or <label> of its
    // own — the visible caption is a SIBLING node — so the metadata search above
    // finds nothing. Fall back to the caption and climb to the block that actually
    // holds a control, which is the thing the reader has to click.
    let target = control ? (control.closest('label,fieldset,[role=group],div') || control) : null;
    if (!target) {
      const caption = [...document.querySelectorAll('label,span,div')]
        .filter(el => visible(el) && (el.textContent || '').trim().toLowerCase() === wanted)
        .sort((a, b) => a.textContent.length - b.textContent.length)[0];
      if (!caption) continue;
      let node = caption;
      for (let up = 0; up < 5 && node; up++) {
        if (node.querySelector('input,select,textarea,[role=combobox],[role=listbox],button')) { target = node; break; }
        node = node.parentElement;
      }
      if (!target) continue;
    }
    target.style.outline = '3px solid #10b981';
    target.style.outlineOffset = '3px';
    target.style.borderRadius = '6px';
    targets.push(target);
    marked++;
  }
  frame(targets);
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
	if err := expandNav(ctx); err != nil {
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
	if err := idpcapture.Screenshot(ctx, outDir, name); err != nil {
		return err
	}
	if name == "google-08-client-created" {
		if err := markGoogleCredentialDialog(ctx); err != nil {
			return err
		}
		return idpcapture.ScreenshotElement(ctx, outDir, name+"-docs", "[data-emisar-docs-google-credentials=true]")
	}
	height := 900
	width := 1155
	if name == "google-02-audience" || name == "google-06-clients" {
		height = 360
	}
	if name == "google-07-web-application" {
		width = 550
		height = 790
	}
	if err := markGoogleDocsPanel(ctx, width, height); err != nil {
		return err
	}
	return idpcapture.ScreenshotElement(ctx, outDir, name+"-docs", "[data-emisar-docs-google-panel=true]")
}

func markGoogleDocsPanel(ctx context.Context, width, height int) error {
	script := fmt.Sprintf(`(() => {
  const gemini = [...document.querySelectorAll('*')]
    .filter(el => (el.textContent || '').trim().startsWith('Try agentic Gemini CLI in Cloud Shell'))
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  let promo = gemini;
  for (let up = 0; up < 8 && promo && getComputedStyle(promo).position !== 'fixed'; up++) promo = promo.parentElement;
  if (promo) promo.style.display = 'none';
  document.querySelector('[data-emisar-docs-google-panel=true]')?.remove();
  const crop = document.createElement('div');
  crop.dataset.emisarDocsGooglePanel = 'true';
  Object.assign(crop.style, {
    position: 'fixed', left: '285px', top: '85px', width: '%dpx', height: '%dpx',
    pointerEvents: 'none', zIndex: '2147483647'
  });
  document.body.appendChild(crop);
  return true;
})()`, width, height)
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return errors.New("could not isolate the Google Auth Platform from account chrome")
	}
	return nil
}

func markGoogleCredentialDialog(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const dialog = [...document.querySelectorAll('[role=dialog]')]
    .find(el => visible(el) && (el.textContent || '').includes('Client ID') &&
      (el.textContent || '').includes('Client secret'));
  if (!dialog) return false;
  dialog.dataset.emisarDocsGoogleCredentials = 'true';
  return true;
})()`
	var marked bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return errors.New("could not isolate the Google OAuth credential dialog")
	}
	return nil
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

// visible separates "the element is not there" from "the page could not be
// asked". Swallowing the evaluate error collapsed the two, so a detached frame
// or a mid-navigation page read as every selector being absent — which drove
// the sign-in state machine past the identifier, password, and TOTP steps
// without submitting any of them.
func visible(ctx context.Context, selector string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const el = document.querySelector(%q);
  return !!el && (el.offsetWidth > 0 || el.offsetHeight > 0);
})()`, selector)
	var ok bool
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &ok)); err != nil {
		return false, fmt.Errorf("checking whether %s is visible: %w", selector, err)
	}
	return ok, nil
}

func totpField(ctx context.Context) (string, error) {
	for _, selector := range []string{`input[name="totpPin"]`, `#totpPin`, `input[type="tel"]`} {
		shown, err := visible(ctx, selector)
		if err != nil {
			return "", err
		}
		if shown {
			return selector, nil
		}
	}
	return "", nil
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
	description = redactGoogleText(description, env)
	fmt.Println("--- page ---")
	fmt.Println(description)
	return nil
}

func redactGoogleText(value string, env map[string]string) string {
	for _, configured := range env {
		if configured != "" {
			value = strings.ReplaceAll(value, configured, "<redacted>")
		}
	}
	value = googleClientIDPattern.ReplaceAllString(value, "<redacted-client-id>")
	return googleClientSecretPattern.ReplaceAllString(value, "<redacted-client-secret>")
}
