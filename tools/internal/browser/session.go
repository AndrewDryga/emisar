package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"os/exec"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/chromedp"
)

type Session struct {
	Context context.Context
	cancel  context.CancelFunc
	alloc   context.CancelFunc
	cleanup func()
	// lifeline is the owner-held write end tying the browser tree's lifetime to this process:
	// the kernel closes it if we die (even by SIGKILL) and the wrapper's watchdog then reaps the
	// whole tree. Close() closes it explicitly as a belt. Nil for daemon-attached sessions, whose
	// browser the daemon owns.
	lifeline *os.File
	BaseURL  string
}

func (m *Manager) Session(ctx context.Context, baseURL string, isolated bool) (*Session, error) {
	if isolated {
		return m.isolatedSession(ctx, baseURL)
	}
	state, err := m.State()
	if err != nil {
		return nil, err
	}
	allocator, cancelAllocator := chromedp.NewRemoteAllocator(ctx, state.WSEndpoint)
	tab, cancelTab := chromedp.NewContext(allocator)
	if err := chromedp.Run(tab); err != nil {
		cancelTab()
		cancelAllocator()
		return nil, err
	}
	return &Session{Context: tab, cancel: cancelTab, alloc: cancelAllocator, BaseURL: baseURL}, nil
}

func (m *Manager) isolatedSession(ctx context.Context, baseURL string) (*Session, error) {
	return m.isolatedSessionWithOptions(ctx, baseURL)
}

func (m *Manager) isolatedSessionWithOptions(ctx context.Context, baseURL string, extra ...chromedp.ExecAllocatorOption) (*Session, error) {
	chrome, err := ResolveChrome()
	if err != nil {
		return nil, err
	}
	profile, err := os.MkdirTemp("", "emisar-browser-isolated-*")
	if err != nil {
		return nil, err
	}
	cleanup := func() { _ = os.RemoveAll(profile) }
	options := []chromedp.ExecAllocatorOption{
		chromedp.ExecPath(chrome), chromedp.UserDataDir(profile),
		chromedp.NoFirstRun, chromedp.NoDefaultBrowserCheck,
		chromedp.Flag("headless", "new"),
		chromedp.Flag("force-prefers-reduced-motion", true),
	}
	if m.SPKI != "" {
		options = append(options, chromedp.Flag("ignore-certificate-errors-spki-list", m.SPKI))
	}
	if m.InBox {
		options = append(options,
			chromedp.Flag("no-sandbox", true),
			chromedp.Flag("disable-dev-shm-usage", true),
			chromedp.Flag("disable-gpu", true),
			// A box or CI runner starts Chrome cold while the rest of the suite
			// saturates its cores, and chromedp's 20s default for the WebSocket
			// URL loses that race intermittently. A workstation keeps the short
			// default so a genuinely dead Chrome still fails fast.
			chromedp.WSURLReadTimeout(90*time.Second),
		)
	}
	options = append(options, extra...)
	// The lifeline replaces chromedp's default Pdeathsig, which fork drops (see lifeline.go).
	keep, child, err := newLifeline()
	if err != nil {
		cleanup()
		return nil, err
	}
	options = append(options, chromedp.ModifyCmdFunc(func(cmd *exec.Cmd) { wrapWithLifeline(cmd, child) }))
	allocator, cancelAllocator := chromedp.NewExecAllocator(ctx, options...)
	tab, cancelTab := chromedp.NewContext(allocator)
	if err := chromedp.Run(tab); err != nil {
		cancelTab()
		cancelAllocator()
		_ = child.Close()
		_ = keep.Close()
		cleanup()
		return nil, err
	}
	// The wrapper holds the read end now; dropping the owner's copy is fd hygiene only — the
	// EOF that reaps the tree comes from `keep`, the write end this process holds until it dies.
	_ = child.Close()
	return &Session{Context: tab, cancel: cancelTab, alloc: cancelAllocator, cleanup: cleanup, lifeline: keep, BaseURL: baseURL}, nil
}

func (s *Session) Close() {
	s.cancel()
	s.alloc()
	// Belt: even if chromedp's graceful teardown wedged or only killed the wrapper, closing the
	// lifeline EOFs the watchdog, which SIGKILLs the browser's whole process group.
	if s.lifeline != nil {
		_ = s.lifeline.Close()
	}
	if s.cleanup != nil {
		s.cleanup()
	}
}

func (s *Session) Viewport(width, height int64, scale float64, mobile bool) error {
	return chromedp.Run(s.Context, emulation.SetDeviceMetricsOverride(width, height, scale, mobile))
}

func (s *Session) Navigate(target string) error {
	if !strings.HasPrefix(target, "http://") && !strings.HasPrefix(target, "https://") {
		target = s.BaseURL + target
	}
	navigationContext, cancel := context.WithTimeout(s.Context, 15*time.Second)
	defer cancel()
	if strings.Contains(target, "[") {
		if err := chromedp.Run(navigationContext, chromedp.Navigate(s.BaseURL)); err != nil {
			return err
		}
		encoded, _ := json.Marshal(target)
		if err := chromedp.Run(navigationContext, chromedp.Evaluate(`location.href=`+string(encoded), nil)); err != nil {
			return err
		}
	} else if err := chromedp.Run(navigationContext, chromedp.Navigate(target)); err != nil {
		return err
	}
	return s.Ready(10*time.Second, "")
}

const readyScript = `(() => {
  const root = document.querySelector('[data-phx-main]');
  if (root && !root.classList.contains('phx-connected')) return 0;
  const visible = [...document.images].filter(img => {
    const box = img.getBoundingClientRect(); return box.width > 0 && box.height > 0;
  });
  const fontsReady = !document.fonts || document.fonts.status === 'loaded';
  return fontsReady && visible.every(img => img.complete) ? 1 : 2;
})()`

func (s *Session) Ready(timeout time.Duration, target string) error {
	ctx, cancel := context.WithTimeout(s.Context, timeout)
	defer cancel()
	var lastEvaluationError error
	assetDeadline := time.Now().Add(2 * time.Second)
	for {
		var status int
		if err := chromedp.Run(ctx, chromedp.Evaluate(readyScript, &status)); err == nil && (status == 1 || status == 2 && time.Now().After(assetDeadline)) {
			break
		} else if err != nil {
			lastEvaluationError = err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("page did not become ready (%s, evaluation=%v): %w", s.readinessDiagnostic(), lastEvaluationError, ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
	if err := chromedp.Run(ctx, chromedp.Sleep(34*time.Millisecond)); err != nil {
		return err
	}
	if target == "" {
		return nil
	}
	quoted, _ := json.Marshal(target)
	stableScript := `(function(){const el=document.querySelector(` + string(quoted) + `);if(!el)return false;const b=el.getBoundingClientRect();const k=[b.x,b.y,b.width,b.height].join(':');if(el.dataset.shotGeometry===k)return true;el.dataset.shotGeometry=k;return false})()`
	for {
		var stable bool
		if err := chromedp.Run(ctx, chromedp.Evaluate(stableScript, &stable)); err == nil && stable {
			return chromedp.Run(ctx, chromedp.Sleep(34*time.Millisecond))
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("target geometry did not settle: %w", ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (s *Session) readinessDiagnostic() string {
	var diagnostic string
	script := `(function(){const root=document.querySelector('[data-phx-main]');const pending=[...document.images].filter(img=>{const b=img.getBoundingClientRect();return b.width>0&&b.height>0&&!img.complete}).length;return 'url='+location.href+' readyState='+document.readyState+' liveRoot='+(!!root)+' connected='+(root?.classList.contains('phx-connected')||false)+' fonts='+(document.fonts?.status||'unknown')+' pendingImages='+pending})()`
	if err := chromedp.Run(s.Context, chromedp.Evaluate(script, &diagnostic)); err != nil {
		return "diagnostic unavailable: " + err.Error()
	}
	return diagnostic
}

type mailboxMessage struct {
	SentAt   string `json:"sent_at"`
	Subject  string `json:"subject"`
	To       any    `json:"to"`
	TextBody string `json:"text_body"`
}

// mailbox reads the development mailbox. The request runs under ctx so a cancelled tab stops
// an in-flight read instead of waiting out the client timeout.
func mailbox(ctx context.Context, baseURL string) ([]mailboxMessage, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/dev/mailbox/json", nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, fmt.Errorf("mailbox: HTTP %s", response.Status)
	}
	var envelope struct {
		Data []mailboxMessage `json:"data"`
	}
	if err := json.NewDecoder(response.Body).Decode(&envelope); err != nil {
		return nil, err
	}
	return envelope.Data, nil
}

func mailID(message mailboxMessage) string { return message.SentAt + "|" + message.Subject }

var magicLinkPattern = regexp.MustCompile(`https?://[^\s"]*/sign_in/magic/[^\s")]+`)

// magicLinkWait bounds the wait for the sign-in email once the Portal accepted the request.
var magicLinkWait = 20 * time.Second

// ErrSignInRefused marks a sign-in the Portal turned down in its own response.
var ErrSignInRefused = errors.New("sign-in refused")

// signInOutcome is what the document produced by submitting the sign-in form said.
type signInOutcome struct {
	Status  int    `json:"status"`  // HTTP status of that document's navigation response
	Flash   string `json:"flash"`   // the page's error flash, if it rendered one
	Stamped bool   `json:"stamped"` // still the pre-submit document
}

// loginStamp marks the sign-in form's document so the outcome is read from the document the
// submit produced, never from text that was already on the page (the "you must log in" flash
// that lands an anonymous console visit on /sign_in, for one).
const loginStamp = "emisarLoginForm"

const signInOutcomeScript = `(() => {
  const nav = performance.getEntriesByType('navigation')[0];
  const flash = document.querySelector('#flash-error');
  const message = flash ? (flash.querySelector('p:last-of-type') || flash).textContent : '';
  return {
    status: nav && nav.responseStatus ? nav.responseStatus : 0,
    flash: message.replace(/\s+/g, ' ').trim(),
    stamped: document.documentElement.dataset.` + loginStamp + ` === '1' || document.readyState === 'loading'
  };
})()`

// Login signs the tab in as email through the passwordless flow against the development
// mailbox. It returns as soon as the sign-in response itself refuses the request (the
// recipient throttle's flash, the per-IP 429), waits a bounded time for a delayed email, names
// a mailbox transport failure as such, and stops when the tab's context is cancelled. No error
// carries the magic link: its path is the secret half of the split code.
func (s *Session) Login(email string) error {
	current, err := s.CurrentURL()
	if err != nil {
		return err
	}
	if parsed, err := url.Parse(current); err == nil && strings.HasPrefix(parsed.Path, "/app/") {
		return nil
	}
	before, err := mailbox(s.Context, s.BaseURL)
	if err != nil {
		if ctxErr := s.Context.Err(); ctxErr != nil {
			return fmt.Errorf("reading /dev/mailbox before sign-in: %w", ctxErr)
		}
		return fmt.Errorf("reading /dev/mailbox before sign-in: %w", err)
	}
	seen := make(map[string]bool, len(before))
	for _, message := range before {
		seen[mailID(message)] = true
	}
	if err := s.Navigate("/sign_in"); err != nil {
		return err
	}
	if err := chromedp.Run(s.Context,
		chromedp.WaitVisible(`input[type="email"]`, chromedp.ByQuery),
		chromedp.Evaluate(`document.documentElement.dataset.`+loginStamp+` = '1'`, nil),
		chromedp.SendKeys(`input[type="email"]`, email, chromedp.ByQuery),
		chromedp.KeyEvent("\r"),
	); err != nil {
		return err
	}
	outcome, err := s.signInOutcome()
	if err != nil {
		return err
	}
	switch {
	case outcome.Status == http.StatusTooManyRequests:
		return fmt.Errorf("%w: the portal rate-limited sign-in requests from this client (HTTP 429); wait for the window to pass", ErrSignInRefused)
	case outcome.Status >= 400:
		return fmt.Errorf("%w: the sign-in request answered HTTP %d", ErrSignInRefused, outcome.Status)
	case strings.Contains(outcome.Flash, "sign-in emails"):
		// The recipient throttle: five emails per address per 15 minutes. A capture batch that
		// signs in per image spends them fast; one `./run shot` with several `<path> --label`
		// groups shares a single sign-in.
		return fmt.Errorf("%w: the portal answered %q; capture related pages in one ./run shot invocation so they share a sign-in", ErrSignInRefused, outcome.Flash)
	case outcome.Flash != "":
		return fmt.Errorf("%w: the portal answered %q", ErrSignInRefused, outcome.Flash)
	}
	link, err := s.awaitMagicLink(email, seen)
	if err != nil {
		return err
	}
	if err := s.Navigate(link); err != nil {
		return fmt.Errorf("opening the magic link: %w", redactMagicLinkError(err))
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		if current, err := s.CurrentURL(); err == nil {
			if parsed, _ := url.Parse(current); parsed != nil && !strings.HasPrefix(parsed.Path, "/sign_in") {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("sign-in did not leave /sign_in after opening the magic link")
		}
		select {
		case <-s.Context.Done():
			return fmt.Errorf("finishing sign-in: %w", s.Context.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// signInOutcome waits for the submit to replace the stamped form document, then reads what
// the new document says. Evaluate fails while the navigation is mid-flight; that is "not yet".
func (s *Session) signInOutcome() (signInOutcome, error) {
	deadline := time.Now().Add(15 * time.Second)
	for {
		var outcome signInOutcome
		if err := chromedp.Run(s.Context, chromedp.Evaluate(signInOutcomeScript, &outcome)); err == nil && !outcome.Stamped {
			return outcome, nil
		}
		if time.Now().After(deadline) {
			return signInOutcome{}, fmt.Errorf("the sign-in form did not submit")
		}
		select {
		case <-s.Context.Done():
			return signInOutcome{}, fmt.Errorf("submitting the sign-in form: %w", s.Context.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// awaitMagicLink polls the development mailbox for a message to email that arrived after the
// form was submitted, for at most magicLinkWait. The link comes back rebased onto BaseURL.
func (s *Session) awaitMagicLink(email string, seen map[string]bool) (string, error) {
	deadline := time.Now().Add(magicLinkWait)
	var lastPollErr error
	polls := 0
	for {
		messages, pollErr := mailbox(s.Context, s.BaseURL)
		if ctxErr := s.Context.Err(); ctxErr != nil {
			// A cancelled tab is neither a transport failure nor a missing email, whichever
			// the read that it interrupted would otherwise have reported.
			return "", fmt.Errorf("waiting for the sign-in email: %w", ctxErr)
		}
		lastPollErr = pollErr
		if pollErr == nil {
			polls++
			for _, message := range messages {
				to, _ := json.Marshal(message.To)
				if seen[mailID(message)] || !strings.Contains(string(to), email) {
					continue
				}
				if match := magicLinkPattern.FindString(message.TextBody); match != "" {
					parsed, err := url.Parse(match)
					if err != nil {
						return "", fmt.Errorf("the sign-in email carries an unparseable magic link")
					}
					link := s.BaseURL + parsed.Path
					if parsed.RawQuery != "" {
						link += "?" + parsed.RawQuery
					}
					return link, nil
				}
			}
		}
		if time.Now().After(deadline) {
			if lastPollErr != nil {
				return "", fmt.Errorf("reading /dev/mailbox while waiting for the sign-in email: %w", lastPollErr)
			}
			return "", fmt.Errorf("no magic-link email for %s reached /dev/mailbox within %s of the portal accepting the request (after %d reads)", email, magicLinkWait, polls)
		}
		select {
		case <-s.Context.Done():
			return "", fmt.Errorf("waiting for the sign-in email: %w", s.Context.Err())
		case <-time.After(500 * time.Millisecond):
		}
	}
}

var magicLinkPathPattern = regexp.MustCompile(`/sign_in/magic/[^\s"?#)]+`)

// redactMagicLink strips the token and secret from any magic-link path in text.
func redactMagicLink(text string) string {
	return magicLinkPathPattern.ReplaceAllString(text, "/sign_in/magic/<redacted>")
}

// redactedError is a magic-link navigation failure with the link stripped from its text. It
// keeps a cancelled or timed-out navigation's context error as its cause, so callers still
// match errors.Is(err, context.Canceled); the original error is dropped rather than wrapped,
// so nothing in the chain can print the link.
type redactedError struct {
	text  string
	cause error
}

func (e *redactedError) Error() string { return e.text }

func (e *redactedError) Unwrap() error { return e.cause }

// redactMagicLinkError rebuilds err with any magic-link path redacted from its text while
// preserving its context.Canceled or context.DeadlineExceeded identity.
func redactMagicLinkError(err error) error {
	redacted := &redactedError{text: redactMagicLink(err.Error())}
	switch {
	case errors.Is(err, context.Canceled):
		redacted.cause = context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		redacted.cause = context.DeadlineExceeded
	}
	return redacted
}
