package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/cdproto/fetch"
	cdpinput "github.com/chromedp/cdproto/input"
	"github.com/chromedp/cdproto/page"
	cdpruntime "github.com/chromedp/cdproto/runtime"
	"github.com/chromedp/chromedp"
)

type PaddleConfig struct {
	BaseURL string
	Out     string
	Email   string
	Log     io.Writer
}

type paddleTargetSet struct {
	session  *Session
	contexts map[string]cdpruntime.ExecutionContextID
}

func newPaddleTargetSet(session *Session) *paddleTargetSet {
	return &paddleTargetSet{session: session, contexts: make(map[string]cdpruntime.ExecutionContextID)}
}

func (p *paddleTargetSet) Refresh() (int, error) {
	listContext, cancelList := context.WithTimeout(p.session.Context, 5*time.Second)
	defer cancelList()
	var lastError error
	err := chromedp.Run(listContext, chromedp.ActionFunc(func(actionContext context.Context) error {
		tree, treeErr := page.GetFrameTree().Do(actionContext)
		if treeErr != nil {
			return treeErr
		}
		var visit func(*page.FrameTree)
		visit = func(frame *page.FrameTree) {
			if isPaddleURL(frame.Frame.URL) {
				key := string(frame.Frame.ID)
				executionContext, worldErr := page.CreateIsolatedWorld(frame.Frame.ID).
					WithWorldName("emisar-paddle-e2e").
					Do(actionContext)
				if worldErr != nil {
					lastError = worldErr
				} else {
					p.contexts[key] = executionContext
				}
			}
			for _, child := range frame.ChildFrames {
				visit(child)
			}
		}
		visit(tree)
		return nil
	}))
	if err != nil {
		return len(p.contexts), err
	}
	return len(p.contexts), lastError
}

func isPaddleURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return host == "paddle.com" || strings.HasSuffix(host, ".paddle.com")
}

func (p *paddleTargetSet) run(action func(context.Context, cdpruntime.ExecutionContextID) (bool, error)) (bool, error) {
	if _, err := p.Refresh(); err != nil && len(p.contexts) == 0 {
		return false, err
	}
	var lastError error
	for _, executionContext := range p.contexts {
		actionContext, cancel := context.WithTimeout(p.session.Context, 5*time.Second)
		found, actionErr := action(actionContext, executionContext)
		cancel()
		if actionErr == nil && found {
			return true, nil
		}
		if actionErr != nil {
			lastError = actionErr
		}
	}
	if lastError != nil {
		return false, lastError
	}
	return false, nil
}

func evaluatePaddleBool(ctx context.Context, executionContext cdpruntime.ExecutionContextID, script string) (bool, error) {
	var value bool
	err := chromedp.Run(ctx, chromedp.ActionFunc(func(actionContext context.Context) error {
		result, exception, err := cdpruntime.Evaluate(script).
			WithContextID(executionContext).
			WithReturnByValue(true).
			WithUserGesture(true).
			Do(actionContext)
		if err != nil {
			return err
		}
		if exception != nil {
			return fmt.Errorf("Paddle frame evaluation failed: %s", exception.Text)
		}
		return json.Unmarshal([]byte(result.Value), &value)
	}))
	return value, err
}

func evaluatePaddleString(ctx context.Context, executionContext cdpruntime.ExecutionContextID, script string) (string, error) {
	var value string
	err := chromedp.Run(ctx, chromedp.ActionFunc(func(actionContext context.Context) error {
		result, exception, err := cdpruntime.Evaluate(script).
			WithContextID(executionContext).
			WithReturnByValue(true).
			Do(actionContext)
		if err != nil {
			return err
		}
		if exception != nil {
			return fmt.Errorf("Paddle frame evaluation failed: %s", exception.Text)
		}
		return json.Unmarshal([]byte(result.Value), &value)
	}))
	return value, err
}

func (p *paddleTargetSet) inventory() string {
	_, _ = p.Refresh()
	var fields []string
	const script = `([...document.querySelectorAll('input,button,select')].map(el=>[el.tagName,el.name||'',el.getAttribute('data-testid')||'',el.placeholder||'',el.tagName==='BUTTON'?(el.textContent||'').trim().slice(0,30):''].join('|')).join('; '))`
	for _, executionContext := range p.contexts {
		ctx, cancel := context.WithTimeout(p.session.Context, 5*time.Second)
		value, err := evaluatePaddleString(ctx, executionContext, script)
		cancel()
		if err == nil && value != "" {
			fields = append(fields, value)
		}
	}
	return strings.Join(fields, "; ")
}

func fillPaddle(targets *paddleTargetSet, selectors []string, value, label string) error {
	for range 15 {
		found, err := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
			selectorsJSON, _ := json.Marshal(selectors)
			valueJSON, _ := json.Marshal(value)
			focusScript := `(function(selectors){for(const selector of selectors){const el=document.querySelector(selector);if(!el)continue;const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;if(setter)setter.call(el,'');else el.value='';el.dispatchEvent(new Event('input',{bubbles:true}));el.focus();return document.activeElement===el}return false})(` + string(selectorsJSON) + `)`
			focused, focusErr := evaluatePaddleBool(frameContext, executionContext, focusScript)
			if focusErr != nil || !focused {
				return false, focusErr
			}
			if insertErr := chromedp.Run(frameContext, chromedp.ActionFunc(func(actionContext context.Context) error {
				return cdpinput.InsertText(value).Do(actionContext)
			})); insertErr != nil {
				return false, insertErr
			}
			time.Sleep(100 * time.Millisecond)
			verifyScript := `(function(selectors,value){const norm=s=>s.replace(/[^A-Za-z0-9@.]/g,'');for(const selector of selectors){const el=document.querySelector(selector);if(el)return el.value===value||norm(el.value)===norm(value)}return false})(` + string(selectorsJSON) + `,` + string(valueJSON) + `)`
			return evaluatePaddleBool(frameContext, executionContext, verifyScript)
		})
		if err != nil {
			return err
		}
		if found {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("%s: no hosted-field selector accepted the value (fields: %s)", label, targets.inventory())
}

func clickPaddle(targets *paddleTargetSet, selectors []string, label string) error {
	for range 10 {
		found, err := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
			selectorsJSON, _ := json.Marshal(selectors)
			script := `(function(selectors){for(const selector of selectors){const el=document.querySelector(selector);if(el){el.click();return true}}return false})(` + string(selectorsJSON) + `)`
			return evaluatePaddleBool(frameContext, executionContext, script)
		})
		if err != nil {
			return err
		}
		if found {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("%s: no selector matched", label)
}

func paddlePresent(targets *paddleTargetSet, selector string) bool {
	found, _ := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
		selectorJSON, _ := json.Marshal(selector)
		return evaluatePaddleBool(frameContext, executionContext, `!!document.querySelector(`+string(selectorJSON)+`)`)
	})
	return found
}

func selectPaddleCountry(targets *paddleTargetSet) error {
	found, err := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
		script := `(function(){const el=document.querySelector('select[name="countryCode"]');if(!el)return false;el.value='US';el.dispatchEvent(new Event('change',{bubbles:true}));return el.value==='US'})()`
		return evaluatePaddleBool(frameContext, executionContext, script)
	})
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("country selector was not found")
	}
	return nil
}

func consentPaddle(targets *paddleTargetSet) error {
	found, err := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
		script := `(function(){const el=document.querySelector('[data-testid="us-compliance-checkbox"]');if(!el)return false;if(!el.checked)el.click();return el.checked})()`
		return evaluatePaddleBool(frameContext, executionContext, script)
	})
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("recurring-charge consent was not found or checked")
	}
	return nil
}

func clickPaddlePay(targets *paddleTargetSet) error {
	found, err := targets.run(func(frameContext context.Context, executionContext cdpruntime.ExecutionContextID) (bool, error) {
		script := `(function(){const buttons=[...document.querySelectorAll('button')];const button=buttons.find(b=>/paymentformsubmit/i.test(b.getAttribute('data-testid')||''))||buttons.find(b=>/pay|subscribe|start trial/i.test(b.textContent));if(!button)return false;button.click();return true})()`
		return evaluatePaddleBool(frameContext, executionContext, script)
	})
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("Paddle payment button was not found")
	}
	return nil
}

func waitURL(session *Session, contains string, attempts int, delay time.Duration) (string, error) {
	for range attempts {
		current, err := session.CurrentURL()
		if err == nil && strings.Contains(current, contains) {
			return current, nil
		}
		var flash string
		if evaluateErr := chromedp.Run(session.Context, chromedp.Evaluate(`document.querySelector('#flash-error')?.innerText || ''`, &flash)); evaluateErr == nil && strings.TrimSpace(flash) != "" {
			return current, fmt.Errorf("checkout rejected: %s", strings.Join(strings.Fields(flash), " "))
		}
		time.Sleep(delay)
	}
	current, _ := session.CurrentURL()
	return current, fmt.Errorf("URL did not contain %q (got %s)", contains, current)
}

func waitForCompletedCheckout(session *Session) error {
	for range 45 {
		current, err := session.CurrentURL()
		if err == nil {
			parsed, parseErr := url.Parse(current)
			if parseErr == nil && strings.HasSuffix(parsed.Path, "/settings/billing") && parsed.Query().Get("_ptxn") == "" {
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	current, _ := session.CurrentURL()
	return fmt.Errorf("Paddle checkout did not return to billing without _ptxn (got %s)", current)
}

func PaddlePurchase(ctx context.Context, manager *Manager, config PaddleConfig) error {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Minute)
	defer cancel()
	if config.Email == "" {
		config.Email = "demo@emisar.dev"
	}
	logf := func(format string, args ...any) {
		if config.Log != nil {
			fmt.Fprintf(config.Log, format+"\n", args...)
		}
	}
	if err := os.MkdirAll(config.Out, 0o755); err != nil {
		return err
	}
	// This isolated, disposable sandbox session keeps Paddle's cross-origin
	// frames in the parent CDP frame tree so the Go driver can address their
	// execution contexts without a Node browser bridge. Other browser commands
	// retain Chrome's normal site isolation.
	session, err := manager.isolatedSessionWithOptions(ctx, config.BaseURL,
		chromedp.Flag("disable-site-isolation-trials", true),
		chromedp.Flag("disable-features", "IsolateOrigins,site-per-process"),
	)
	if err != nil {
		return err
	}
	defer session.Close()
	if err := session.Viewport(1440, 1024, 1, false); err != nil {
		return err
	}
	chromedp.ListenTarget(session.Context, func(event any) {
		paused, ok := event.(*fetch.EventRequestPaused)
		if !ok {
			return
		}
		go func() {
			_ = chromedp.Run(session.Context, chromedp.ActionFunc(func(actionContext context.Context) error {
				if strings.HasPrefix(paused.Request.URL, "https://localhost:4000/") {
					location := strings.Replace(paused.Request.URL, "https://", "http://", 1)
					return fetch.FulfillRequest(paused.RequestID, 302).
						WithResponseHeaders([]*fetch.HeaderEntry{{Name: "Location", Value: location}}).
						Do(actionContext)
				}
				return fetch.ContinueRequest(paused.RequestID).Do(actionContext)
			}))
		}()
	})
	if err := chromedp.Run(session.Context, chromedp.ActionFunc(func(actionContext context.Context) error {
		return fetch.Enable().Do(actionContext)
	})); err != nil {
		return err
	}
	if err := session.Login(config.Email); err != nil {
		return err
	}
	logf("billing e2e: signed in")
	if err := session.Navigate("/app/demo/settings/billing"); err != nil {
		return err
	}
	if err := session.ViewportScreenshot(filepath.Join(config.Out, "e2e-1-billing.png")); err != nil {
		return err
	}
	var clicked bool
	if err := chromedp.Run(session.Context, chromedp.Evaluate(`(()=>{const b=document.querySelector("button[phx-click='upgrade'][phx-value-plan='team']");if(b)b.click();return !!b})()`, &clicked)); err != nil {
		return err
	}
	if !clicked {
		return fmt.Errorf("no Upgrade-to-team button on billing page")
	}
	if _, err := waitURL(session, "_ptxn=", 30, time.Second); err != nil {
		_ = session.ViewportScreenshot(filepath.Join(config.Out, "e2e-2-checkout-failed.png"))
		return err
	}
	logf("billing e2e: checkout transaction opened")
	time.Sleep(6 * time.Second)
	if err := session.ViewportScreenshot(filepath.Join(config.Out, "e2e-2-overlay.png")); err != nil {
		return err
	}
	targets := newPaddleTargetSet(session)
	targetReady := false
	var targetError error
	for range 60 {
		count, refreshErr := targets.Refresh()
		if refreshErr != nil {
			targetError = refreshErr
		}
		if count > 0 {
			targetReady = true
			break
		}
		time.Sleep(time.Second)
	}
	if !targetReady {
		return fmt.Errorf("Paddle did not create a hosted checkout target: %v", targetError)
	}
	logf("billing e2e: hosted checkout attached")
	if err := fillPaddle(targets, []string{`[data-testid="authenticationEmailInput"]`, `input[name="email"]`}, config.Email, "email"); err != nil {
		return err
	}
	if err := selectPaddleCountry(targets); err != nil {
		return err
	}
	for round := 0; round < 4 && paddlePresent(targets, `[data-testid="authenticationEmailInput"]`); round++ {
		if paddlePresent(targets, `[data-testid="postcodeInput"]`) {
			if err := fillPaddle(targets, []string{`[data-testid="postcodeInput"]`}, "90210", "postcode"); err != nil {
				return err
			}
		}
		if err := clickPaddle(targets, []string{`[data-testid="combinedAuthenticationLocationFormSubmitButton"]`}, "identity Continue"); err != nil {
			return err
		}
		time.Sleep(6 * time.Second)
	}
	if paddlePresent(targets, `[data-testid="authenticationEmailInput"]`) {
		return fmt.Errorf("Paddle identity step did not advance")
	}
	logf("billing e2e: identity accepted")
	if err := consentPaddle(targets); err != nil {
		return err
	}
	fields := []struct {
		selectors []string
		value     string
		label     string
	}{
		{[]string{`[data-testid="cardNumberInput"]`, `input[name="cardNumber"]`, `input[id="cardNumber"]`}, "4242424242424242", "card number"},
		{[]string{`[data-testid="cardholderNameInput"]`, `input[name="cardholderName"]`, `input[name="name"]`}, "Demo Operator", "cardholder"},
		{[]string{`[data-testid="expiryDateField"]`, `input[name="expiry"]`, `[data-testid="cardExpiryInput"]`}, "12/30", "expiry"},
		{[]string{`[data-testid="cardVerificationValueInput"]`, `input[name="verificationValue"]`, `input[name="cvv"]`}, "100", "cvc"},
	}
	for _, field := range fields {
		if err := fillPaddle(targets, field.selectors, field.value, field.label); err != nil {
			return err
		}
	}
	if paddlePresent(targets, `[data-testid="postcodeInput"]`) {
		if err := fillPaddle(targets, []string{`[data-testid="postcodeInput"]`}, "90210", "postcode (card step)"); err != nil {
			return err
		}
	}
	if err := session.ViewportScreenshot(filepath.Join(config.Out, "e2e-3-filled.png")); err != nil {
		return err
	}
	if err := clickPaddlePay(targets); err != nil {
		return err
	}
	logf("billing e2e: payment submitted")
	if err := waitForCompletedCheckout(session); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	return session.ViewportScreenshot(filepath.Join(config.Out, "e2e-4-after-payment.png"))
}
