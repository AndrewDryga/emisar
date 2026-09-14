//go:build !windows

package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// signInFixture plays the Portal's passwordless sign-in surface as the browser sees it: the
// /sign_in form, the controller's redirect to the "sent" page (with the recipient-throttle flash
// when refused, or a bare 429 when the per-IP plug rejects), the dev mailbox, the emailed magic
// link, and a cookie-gated console. It records how many sign-in requests and emails one session
// spends, which is what the throttle counts.
type signInFixture struct {
	server *httptest.Server

	mu          sync.Mutex
	refuse      string // "" accepts; "throttle" redirects with the flash; "ip" answers 429
	mailDelay   time.Duration
	mailStall   time.Duration // how long /dev/mailbox/json holds each read before answering
	mailFail    bool
	mailNever   bool
	starts      int
	messages    []mailboxMessage
	secret      string
	staleFlash  bool
	linkExpired bool          // the magic link bounces back to the sent page instead of signing in
	linkStall   time.Duration // how long the magic link holds its response before answering
	linkOpened  chan struct{} // receives once when the magic link is requested, if set
	lastRequest string
}

const fixtureSecret = "SECRET-CODE-DO-NOT-LOG"

func newSignInFixture(t *testing.T) *signInFixture {
	t.Helper()
	fixture := &signInFixture{secret: fixtureSecret, staleFlash: true}
	mux := http.NewServeMux()
	mux.HandleFunc("/sign_in", func(w http.ResponseWriter, r *http.Request) {
		fixture.mu.Lock()
		stale := fixture.staleFlash
		fixture.mu.Unlock()
		flash := ""
		if stale {
			// The redirect that lands an anonymous console visit on /sign_in carries this flash;
			// it is on the page BEFORE the form is submitted and must never read as a refusal.
			flash = `<div id="flash-error" role="alert" data-flash><p>Something went wrong</p><p>You must log in to access this page.</p></div>`
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = fmt.Fprintf(w, `<!doctype html><html><body>%s<form action="/sign_in/magic/start" method="post"><input type="email" name="user[email]" required><button>Send sign-in link</button></form></body></html>`, flash)
	})
	mux.HandleFunc("/sign_in/magic/start", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		email := r.FormValue("user[email]")
		fixture.mu.Lock()
		fixture.starts++
		refuse := fixture.refuse
		delay := fixture.mailDelay
		never := fixture.mailNever
		fixture.mu.Unlock()
		switch refuse {
		case "ip":
			w.Header().Set("Retry-After", "60")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"error":"rate_limited","message":"Too many requests. Retry in 60s."}`))
			return
		case "throttle":
			http.Redirect(w, r, "/sign_in/magic?sent=1&refused=1", http.StatusFound)
			return
		}
		if !never {
			go func() {
				time.Sleep(delay)
				fixture.mu.Lock()
				defer fixture.mu.Unlock()
				fixture.messages = append(fixture.messages, mailboxMessage{
					SentAt:   time.Now().UTC().Format(time.RFC3339Nano),
					Subject:  "Your sign-in link",
					To:       []any{[]any{"", email}},
					TextBody: "Open " + fixture.server.URL + "/sign_in/magic/token-1/" + fixture.secret + " to sign in.",
				})
			}()
		}
		http.Redirect(w, r, "/sign_in/magic?sent=1", http.StatusFound)
	})
	mux.HandleFunc("/sign_in/magic", func(w http.ResponseWriter, r *http.Request) {
		flash := ""
		if r.URL.Query().Get("refused") == "1" {
			flash = `<div id="flash-error" role="alert" data-flash><p>Something went wrong</p><p>You've asked for several sign-in emails for that address. Wait a few minutes, then resend.</p></div>`
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = fmt.Fprintf(w, `<!doctype html><html><body>%s<h1>Check your email</h1><form><input name="code"><button id="code-submit">Sign in</button></form></body></html>`, flash)
	})
	mux.HandleFunc("/sign_in/magic/", func(w http.ResponseWriter, r *http.Request) {
		fixture.mu.Lock()
		expired := fixture.linkExpired
		stall := fixture.linkStall
		opened := fixture.linkOpened
		fixture.mu.Unlock()
		if opened != nil {
			select {
			case opened <- struct{}{}:
			default:
			}
		}
		time.Sleep(stall)
		if expired || !strings.HasSuffix(r.URL.Path, "/"+fixture.secret) {
			http.Redirect(w, r, "/sign_in/magic", http.StatusFound)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "signed-in", Path: "/"})
		http.Redirect(w, r, "/app/demo", http.StatusFound)
	})
	mux.HandleFunc("/dev/mailbox/json", func(w http.ResponseWriter, r *http.Request) {
		fixture.mu.Lock()
		stall := fixture.mailStall
		fixture.mu.Unlock()
		time.Sleep(stall)
		fixture.mu.Lock()
		defer fixture.mu.Unlock()
		if fixture.mailFail {
			http.Error(w, "mailbox exploded", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"data": fixture.messages})
	})
	mux.HandleFunc("/app/", func(w http.ResponseWriter, r *http.Request) {
		if cookie, err := r.Cookie("session"); err != nil || cookie.Value != "signed-in" {
			http.Redirect(w, r, "/sign_in", http.StatusFound)
			return
		}
		fixture.mu.Lock()
		fixture.lastRequest = r.URL.Path
		fixture.mu.Unlock()
		w.Header().Set("Content-Type", "text/html")
		_, _ = fmt.Fprintf(w, `<!doctype html><html><body><h1>%s</h1></body></html>`, r.URL.Path)
	})
	fixture.server = httptest.NewServer(mux)
	t.Cleanup(fixture.server.Close)
	return fixture
}

func (f *signInFixture) set(change func(*signInFixture)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change(f)
}

func (f *signInFixture) startCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.starts
}

func (f *signInFixture) mailCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.messages)
}

// signInBrowser starts one isolated Chromium for a test and hands out fresh, cookie-less tabs
// from it, so the outcome cases share a single cold start instead of paying one each.
func signInBrowser(t *testing.T, baseURL string) *Session {
	t.Helper()
	if _, err := ResolveChrome(); err != nil {
		t.Skip(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	t.Cleanup(cancel)
	session, err := New(Config{InBox: testInBox()}).isolatedSessionWithOptions(ctx, baseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.Close)
	return session
}

func freshTab(t *testing.T, browser *Session) (*Session, context.CancelFunc) {
	t.Helper()
	tab, cancel := chromedp.NewContext(browser.Context)
	t.Cleanup(cancel)
	if err := chromedp.Run(tab, network.ClearBrowserCookies()); err != nil {
		t.Fatal(err)
	}
	session := &Session{Context: tab, cancel: cancel, alloc: func() {}, BaseURL: browser.BaseURL}
	if err := session.Navigate("/sign_in"); err != nil {
		t.Fatal(err)
	}
	return session, cancel
}

func shortMagicLinkWait(t *testing.T, wait time.Duration) {
	t.Helper()
	previous := magicLinkWait
	magicLinkWait = wait
	t.Cleanup(func() { magicLinkWait = previous })
}

func TestLoginReportsTheRefusalTheSignInResponseShowed(t *testing.T) {
	fixture := newSignInFixture(t)
	browser := signInBrowser(t, fixture.server.URL)
	shortMagicLinkWait(t, 20*time.Second)

	t.Run("recipient throttle flash", func(t *testing.T) {
		fixture.set(func(f *signInFixture) { f.refuse = "throttle"; f.mailNever = true })
		session, _ := freshTab(t, browser)
		started := time.Now()
		err := session.Login("demo@emisar.dev")
		elapsed := time.Since(started)
		if !errors.Is(err, ErrSignInRefused) {
			t.Fatalf("login error = %v, want a refusal", err)
		}
		if !strings.Contains(err.Error(), "several sign-in emails") || strings.Contains(err.Error(), "mailbox") {
			t.Fatalf("refusal does not carry the page's own message: %v", err)
		}
		if elapsed > 10*time.Second {
			t.Fatalf("refusal took %v; it should not wait out the mailbox poll", elapsed)
		}
	})

	t.Run("per-IP rate limit", func(t *testing.T) {
		fixture.set(func(f *signInFixture) { f.refuse = "ip"; f.mailNever = true })
		session, _ := freshTab(t, browser)
		err := session.Login("demo@emisar.dev")
		if !errors.Is(err, ErrSignInRefused) || !strings.Contains(err.Error(), "429") {
			t.Fatalf("login error = %v, want a 429 refusal", err)
		}
	})
}

func TestLoginDistinguishesMailOutcomes(t *testing.T) {
	fixture := newSignInFixture(t)
	browser := signInBrowser(t, fixture.server.URL)
	shortMagicLinkWait(t, 4*time.Second)

	t.Run("delayed email still signs in", func(t *testing.T) {
		fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = false; f.mailDelay = 1500 * time.Millisecond })
		session, _ := freshTab(t, browser)
		if err := session.Login("demo@emisar.dev"); err != nil {
			t.Fatalf("login: %v", err)
		}
		current, _ := session.CurrentURL()
		if !strings.Contains(current, "/app/demo") {
			t.Fatalf("login left the tab on %s", current)
		}
	})

	t.Run("no email is not a refusal", func(t *testing.T) {
		fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = true })
		session, _ := freshTab(t, browser)
		err := session.Login("demo@emisar.dev")
		if err == nil || errors.Is(err, ErrSignInRefused) || !strings.Contains(err.Error(), "no magic-link email") {
			t.Fatalf("login error = %v, want a no-email report", err)
		}
		if strings.Contains(err.Error(), "HTTP") {
			t.Fatalf("no-email report reads like a transport failure: %v", err)
		}
	})

	t.Run("mailbox transport failure is named", func(t *testing.T) {
		fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = true; f.mailFail = false })
		session, _ := freshTab(t, browser)
		// The pre-submit baseline read succeeds; the mailbox then dies while the poll runs.
		go func() {
			time.Sleep(500 * time.Millisecond)
			fixture.set(func(f *signInFixture) { f.mailFail = true })
		}()
		t.Cleanup(func() { fixture.set(func(f *signInFixture) { f.mailFail = false }) })
		err := session.Login("demo@emisar.dev")
		if err == nil || errors.Is(err, ErrSignInRefused) || !strings.Contains(err.Error(), "/dev/mailbox") || !strings.Contains(err.Error(), "HTTP 500") {
			t.Fatalf("login error = %v, want the mailbox failure", err)
		}
	})

	t.Run("cancellation stops the wait", func(t *testing.T) {
		shortMagicLinkWait(t, 30*time.Second)
		fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = true })
		session, cancel := freshTab(t, browser)
		go func() {
			time.Sleep(time.Second)
			cancel()
		}()
		started := time.Now()
		err := session.Login("demo@emisar.dev")
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("login error = %v, want context.Canceled", err)
		}
		if elapsed := time.Since(started); elapsed > 5*time.Second {
			t.Fatalf("cancellation took %v", elapsed)
		}
	})

	t.Run("cancellation during a stalled baseline read is not a transport failure", func(t *testing.T) {
		// The mailbox holds the pre-submit read for 3s and then dies; the tab is cancelled long
		// before that. The report must be the cancellation, now, not the 500 the read ended in.
		fixture.set(func(f *signInFixture) {
			f.refuse = ""
			f.mailNever = true
			f.mailStall = 3 * time.Second
			f.mailFail = true
		})
		t.Cleanup(func() { fixture.set(func(f *signInFixture) { f.mailStall = 0; f.mailFail = false }) })
		session, cancel := freshTab(t, browser)
		go func() {
			time.Sleep(300 * time.Millisecond)
			cancel()
		}()
		started := time.Now()
		err := session.Login("demo@emisar.dev")
		if !errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "HTTP") {
			t.Fatalf("login error = %v, want context.Canceled", err)
		}
		if elapsed := time.Since(started); elapsed > 2*time.Second {
			t.Fatalf("cancellation waited out the stalled read: %v", elapsed)
		}
	})

	t.Run("cancellation during a stalled poll is not a missing email", func(t *testing.T) {
		// The baseline read passes; the polls then stall past magicLinkWait. Cancelling the tab
		// while a poll is in flight must report the cancellation, not the deadline it overran.
		shortMagicLinkWait(t, time.Second)
		fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = true; f.mailStall = 0 })
		t.Cleanup(func() { fixture.set(func(f *signInFixture) { f.mailStall = 0 }) })
		session, cancel := freshTab(t, browser)
		go func() {
			time.Sleep(500 * time.Millisecond)
			fixture.set(func(f *signInFixture) { f.mailStall = 2 * time.Second })
			time.Sleep(500 * time.Millisecond)
			cancel()
		}()
		started := time.Now()
		err := session.Login("demo@emisar.dev")
		if !errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "no magic-link email") {
			t.Fatalf("login error = %v, want context.Canceled", err)
		}
		if elapsed := time.Since(started); elapsed > 2*time.Second {
			t.Fatalf("cancellation waited out the stalled poll: %v", elapsed)
		}
	})

	t.Run("cancellation while opening the magic link keeps its identity", func(t *testing.T) {
		// The email is there at once and the magic link's response then hangs. A tab cancelled
		// mid-navigation must still read as context.Canceled to the caller: the redaction that
		// keeps the link out of the text must not strip the cancellation's identity with it.
		opened := make(chan struct{}, 1)
		fixture.set(func(f *signInFixture) {
			f.refuse = ""
			f.mailNever = false
			f.mailDelay = 0
			f.mailStall = 0
			f.linkStall = 5 * time.Second
			f.linkOpened = opened
		})
		t.Cleanup(func() { fixture.set(func(f *signInFixture) { f.linkStall = 0; f.linkOpened = nil }) })
		session, cancel := freshTab(t, browser)
		go func() {
			select {
			case <-opened:
			case <-time.After(20 * time.Second):
			}
			cancel()
		}()
		started := time.Now()
		err := session.Login("demo@emisar.dev")
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("login error = %v, want context.Canceled", err)
		}
		if strings.Contains(err.Error(), fixtureSecret) || strings.Contains(err.Error(), "/sign_in/magic/token-1") {
			t.Fatalf("login error leaks the magic link: %v", err)
		}
		if elapsed := time.Since(started); elapsed > 4*time.Second {
			t.Fatalf("cancellation waited out the stalled navigation: %v", elapsed)
		}
	})
}

// A sign-in that fails late (the magic link opened but never signed the tab in) must not print
// the link: its path carries the secret half of the split code.
func TestLoginErrorsNeverCarryTheMagicLinkSecret(t *testing.T) {
	fixture := newSignInFixture(t)
	browser := signInBrowser(t, fixture.server.URL)
	shortMagicLinkWait(t, 4*time.Second)
	fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = false; f.mailDelay = 0; f.linkExpired = true })
	session, _ := freshTab(t, browser)
	err := session.Login("demo@emisar.dev")
	if err == nil {
		t.Fatal("login succeeded through an expired link")
	}
	if strings.Contains(err.Error(), fixtureSecret) || strings.Contains(err.Error(), "/sign_in/magic/token-1") {
		t.Fatalf("login error leaks the magic link: %v", err)
	}
}

func TestRedactMagicLinkStripsTokenAndSecret(t *testing.T) {
	text := "page did not become ready (url=https://localhost:4000/sign_in/magic/token-1/" + fixtureSecret + "?return_to=%2Fapp readyState=loading)"
	got := redactMagicLink(text)
	if strings.Contains(got, fixtureSecret) || strings.Contains(got, "token-1") || !strings.Contains(got, "/sign_in/magic/<redacted>?return_to") {
		t.Fatalf("redactMagicLink = %q", got)
	}
	if redactMagicLink("/sign_in/magic?sent=1") != "/sign_in/magic?sent=1" {
		t.Fatal("the sent page path is not a magic link")
	}
}

func TestRedactMagicLinkErrorKeepsContextIdentityWithoutTheLink(t *testing.T) {
	link := "https://localhost:4000/sign_in/magic/token-1/" + fixtureSecret
	cancelled := redactMagicLinkError(fmt.Errorf("page did not become ready (url=%s): %w", link, context.Canceled))
	if !errors.Is(cancelled, context.Canceled) || errors.Is(cancelled, context.DeadlineExceeded) {
		t.Fatalf("cancelled navigation = %v, want context.Canceled", cancelled)
	}
	timedOut := redactMagicLinkError(fmt.Errorf("target geometry did not settle: %w", context.DeadlineExceeded))
	if !errors.Is(timedOut, context.DeadlineExceeded) {
		t.Fatalf("timed-out navigation = %v, want context.DeadlineExceeded", timedOut)
	}
	plain := redactMagicLinkError(errors.New("net::ERR_CONNECTION_REFUSED at " + link))
	if errors.Is(plain, context.Canceled) || errors.Is(plain, context.DeadlineExceeded) {
		t.Fatalf("plain failure = %v carries a context identity", plain)
	}
	for _, err := range []error{cancelled, timedOut, plain} {
		for unwrapped := err; unwrapped != nil; unwrapped = errors.Unwrap(unwrapped) {
			if strings.Contains(unwrapped.Error(), fixtureSecret) || strings.Contains(unwrapped.Error(), "token-1") {
				t.Fatalf("the error chain of %v still carries the magic link: %v", err, unwrapped)
			}
		}
	}
	if !strings.Contains(cancelled.Error(), "/sign_in/magic/<redacted>") || !strings.Contains(cancelled.Error(), "context canceled") {
		t.Fatalf("redacted text lost its message: %v", cancelled)
	}
}

// One session, several captures, one sign-in: the shape a same-user capture batch relies on.
func TestShotsOnOneSessionSignInOnce(t *testing.T) {
	fixture := newSignInFixture(t)
	browser := signInBrowser(t, fixture.server.URL)
	fixture.set(func(f *signInFixture) { f.refuse = ""; f.mailNever = false })
	session, _ := freshTab(t, browser)
	out := t.TempDir()
	for _, path := range []string{"/app/demo", "/app/demo/runs", "/app/demo/approvals"} {
		if _, err := session.Shot(ShotOptions{Path: path, Label: strings.ReplaceAll(strings.TrimPrefix(path, "/"), "/", "-"), Out: out}); err != nil {
			t.Fatalf("shot %s: %v", path, err)
		}
	}
	if starts, mails := fixture.startCount(), fixture.mailCount(); starts != 1 || mails != 1 {
		t.Fatalf("three shots spent %d sign-in requests and %d emails; want one each", starts, mails)
	}
}
