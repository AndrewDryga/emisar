package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/chromedp"
)

type Session struct {
	Context context.Context
	cancel  context.CancelFunc
	alloc   context.CancelFunc
	cleanup func()
	BaseURL string
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
		chromedp.Flag("ignore-certificate-errors-spki-list", m.SPKI),
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
	allocator, cancelAllocator := chromedp.NewExecAllocator(ctx, options...)
	tab, cancelTab := chromedp.NewContext(allocator)
	if err := chromedp.Run(tab); err != nil {
		cancelTab()
		cancelAllocator()
		cleanup()
		return nil, err
	}
	return &Session{Context: tab, cancel: cancelTab, alloc: cancelAllocator, cleanup: cleanup, BaseURL: baseURL}, nil
}

func (s *Session) Close() {
	s.cancel()
	s.alloc()
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

func mailbox(baseURL string) ([]mailboxMessage, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Get(baseURL + "/dev/mailbox/json")
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

func (s *Session) Login(email string) error {
	var current string
	if err := chromedp.Run(s.Context, chromedp.Location(&current)); err != nil {
		return err
	}
	if parsed, err := url.Parse(current); err == nil && strings.HasPrefix(parsed.Path, "/app/") {
		return nil
	}
	before, err := mailbox(s.BaseURL)
	if err != nil {
		return err
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
		chromedp.SendKeys(`input[type="email"]`, email, chromedp.ByQuery),
		chromedp.KeyEvent("\r"),
	); err != nil {
		return err
	}
	var link string
	for range 40 {
		messages, pollErr := mailbox(s.BaseURL)
		if pollErr == nil {
			for _, message := range messages {
				to, _ := json.Marshal(message.To)
				if seen[mailID(message)] || !strings.Contains(string(to), email) {
					continue
				}
				if match := magicLinkPattern.FindString(message.TextBody); match != "" {
					parsed, _ := url.Parse(match)
					link = s.BaseURL + parsed.Path
					if parsed.RawQuery != "" {
						link += "?" + parsed.RawQuery
					}
					break
				}
			}
		}
		if link != "" {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if link == "" {
		return fmt.Errorf("no magic-link email showed up in /dev/mailbox")
	}
	if err := s.Navigate(link); err != nil {
		return err
	}
	for range 200 {
		if err := chromedp.Run(s.Context, chromedp.Location(&current)); err == nil {
			parsed, _ := url.Parse(current)
			if !strings.HasPrefix(parsed.Path, "/sign_in") {
				return nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("login did not leave /sign_in")
}
