// Command entra-capture drives a live Microsoft Entra tenant to produce the
// /docs/sso#entra walkthrough screenshots, the way okta-capture and
// jumpcloud-capture do for theirs.
//
// Entra's sign-in is a four-screen sequence (email → password → TOTP → "stay
// signed in"), each rendered by the same SPA, so every step waits on the NEXT
// field appearing rather than a fixed sleep.
package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	env := flag.String("env", "portal/.agent/secrets/entra-trial.env", "env file with the tenant credentials")
	outDir := flag.String("out", "/tmp/entra", "directory for the captured PNGs")
	headless := flag.Bool("headless", true, "run Chrome headless")
	flag.Parse()

	values, err := readEnv(*env)
	if err != nil {
		fail(err)
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fail(err)
	}
	if err := run(values, *outDir, *headless); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "entra-capture:", err)
	os.Exit(1)
}

func readEnv(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	values := map[string]string{}
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
		values[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `'"`)
	}
	return values, scanner.Err()
}

func run(env map[string]string, outDir string, headless bool) error {
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
		_ = screenshot(ctx, outDir, "en-login-failed")
		_ = describePage(ctx)
		return err
	}
	fmt.Println("  signed in")
	if err := screenshot(ctx, outDir, "en-01-signed-in"); err != nil {
		return err
	}
	return reportLicences(ctx, outDir)
}

// signIn walks Microsoft's sign-in sequence. Every screen lives in ONE DOM that
// the SPA shows and hides, so a bare `input[type=submit]` matches the hidden
// email screen's button and silently submits nothing — that cost a debugging
// round. Click Microsoft's stable `#idSIButton9` and gate each step on the text
// of the screen that should now be showing, not on a field's mere presence.
func signIn(ctx context.Context, env map[string]string, outDir string) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://entra.microsoft.com/"),
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

		case strings.Contains(body, "Microsoft Entra admin center"),
			strings.Contains(body, "Identity"), strings.Contains(body, "Overview"):
			fmt.Println("  admin center loaded")
			return nil

		default:
			_ = chromedp.Run(ctx, chromedp.Sleep(3*time.Second))
		}
	}
	return fmt.Errorf("never reached the admin center")
}

// waitForText polls the rendered text for a marker of the screen we expect. The
// URL never changes across these steps, so text is the only honest signal that
// the SPA actually advanced.
func waitForText(ctx context.Context, want string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var body string
		if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
			return err
		}
		if strings.Contains(body, want) {
			return nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
			return err
		}
	}
	return fmt.Errorf("timed out waiting for %q", want)
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

	code, err := totpCode(secret)
	if err != nil {
		return err
	}
	fmt.Println("  submitting TOTP", code)
	return chromedp.Run(ctx,
		chromedp.SendKeys(`input[name="otc"]`, code, chromedp.ByQuery),
		chromedp.Click(`input[type="submit"]`, chromedp.ByQuery),
		chromedp.Sleep(6*time.Second),
	)
}

// totpCode is RFC 6238 TOTP-SHA1, 6 digits, 30s step — what an authenticator app
// computes. Keeping it in-process means the secret never leaves this machine and
// no phone is in the loop.
func totpCode(secret string) (string, error) {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).
		DecodeString(strings.ToUpper(strings.ReplaceAll(secret, " ", "")))
	if err != nil {
		return "", fmt.Errorf("decode TOTP secret: %w", err)
	}

	counter := make([]byte, 8)
	binary.BigEndian.PutUint64(counter, uint64(time.Now().Unix()/30))

	mac := hmac.New(sha1.New, key)
	mac.Write(counter)
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

// describePage dumps what the SPA is actually showing, so a failed step is
// diagnosed from the real screen rather than a guess about it.
func describePage(ctx context.Context) error {
	const script = `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  return JSON.stringify({
    url: location.href,
    text: document.body.innerText.slice(0, 900),
    fields: [...document.querySelectorAll('input,textarea,select')].filter(visible)
      .map(el => [el.tagName, el.type || '', 'name=' + (el.name || '-'),
                  'ph=' + (el.placeholder || '-')].join(' ')),
  }, null, 1);
})()`
	var listing string
	if err := chromedp.Run(ctx, chromedp.Evaluate(script, &listing)); err != nil {
		return err
	}
	fmt.Println("--- page ---")
	fmt.Println(listing)
	return nil
}

// reportLicences answers the question the founder's failed checkout left open:
// did the P2 trial actually land? SCIM provisioning needs P1 or better, while
// OIDC sign-in does not — so this decides which half of the Entra certification
// can proceed today.
func reportLicences(ctx context.Context, outDir string) error {
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://entra.microsoft.com/#view/Microsoft_AAD_IAM/LicensesMenuBlade/~/Products"),
		chromedp.Sleep(15*time.Second),
	); err != nil {
		return err
	}
	var body string
	if err := chromedp.Run(ctx, chromedp.Evaluate(`document.body.innerText`, &body)); err != nil {
		return err
	}
	fmt.Println("--- licences ---")
	fmt.Println(body[:min(1200, len(body))])
	return screenshot(ctx, outDir, "en-02-licences")
}
