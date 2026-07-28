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
	if err := chromedp.Run(ctx,
		chromedp.Navigate(env["JUMPCLOUD_CONSOLE_URL"]+"/#/sso/applications"),
		chromedp.Sleep(10*time.Second)); err != nil {
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
	if err := screenshot(ctx, outDir, "jc-03-add-application"); err != nil {
		return err
	}
	return describePage(ctx)
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
