package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"
)

type Anchor struct {
	Selector      string
	Heading       string
	ClassContains []string
	Climb         string
}

type ShotOptions struct {
	Path   string
	Label  string
	Out    string
	Email  string
	Width  int64
	Settle time.Duration
	// Steps run in command-line order after navigation, each waiting for its
	// selector — how a shot reaches state behind a reveal (expand a step, then
	// open its picker) or a flow (type into a form, submit it, open the next).
	Steps  []Step
	Anchor *Anchor
}

// Step is one interaction before the capture: a click, or a fill.
type Step struct {
	Click string
	Fill  *FieldFill
}

// FieldFill replaces an input's value and notifies its form.
type FieldFill struct {
	Selector string
	Value    string
}

func (s *Session) MarkAnchor(anchor Anchor, attribute string) error {
	encoded, err := json.Marshal(anchor)
	if err != nil {
		return err
	}
	attributeJSON, _ := json.Marshal(attribute)
	script := `(function(t,attribute){
 const visible=n=>{if(!n)return false;if(n.checkVisibility)return n.checkVisibility();const b=n.getBoundingClientRect();return b.width>0&&b.height>0};
 let el=t.Selector?document.querySelector(t.Selector):null;
 if(!el&&t.ClassContains&&t.ClassContains.length)el=[...document.querySelectorAll('div,section')].find(d=>visible(d)&&t.ClassContains.every(c=>(d.className||'').includes(c)))||null;
 if(!el&&t.Heading)el=[...document.querySelectorAll('h1,h2,h3,h4,div,span,p,label,legend')].filter(n=>visible(n)&&n.textContent.trim()===t.Heading).sort((a,b)=>a.querySelectorAll('*').length-b.querySelectorAll('*').length)[0]||null;
 if(!el)return false;if(t.Climb)el=el.closest(t.Climb)||el;if(!visible(el))return false;el.setAttribute(attribute,'1');return true;
})(` + string(encoded) + `,` + string(attributeJSON) + `)`
	var marked bool
	if err := chromedp.Run(s.Context, chromedp.Evaluate(script, &marked)); err != nil {
		return err
	}
	if !marked {
		return fmt.Errorf("anchor not found or visible")
	}
	return nil
}

func writeImage(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// FullScreenshot captures the whole document. The tab is brought to the front
// first: Chrome composites no frames for a tab it considers hidden, and a
// capture of such a tab never returns. The isolated browser runs without
// chromedp's occluded-window flags, so a second tab in the same window — the
// shape of a batch of shots after a sign-in — could sit behind the first one
// and hang its capture until the budget ran out.
func (s *Session) FullScreenshot(path string) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, page.BringToFront(), chromedp.FullScreenshot(&image, 100)); err != nil {
		return err
	}
	return writeImage(path, image)
}

func (s *Session) ViewportScreenshot(path string) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, page.BringToFront(), chromedp.CaptureScreenshot(&image)); err != nil {
		return err
	}
	return writeImage(path, image)
}

func (s *Session) ElementScreenshot(selector, path string, scale float64) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, page.BringToFront(), chromedp.ScreenshotScale(selector, scale, &image, chromedp.ByQuery)); err != nil {
		return err
	}
	return writeImage(path, image)
}

func (s *Session) CurrentURL() (string, error) {
	ctx, cancel := context.WithTimeout(s.Context, 5*time.Second)
	defer cancel()
	var current string
	err := chromedp.Run(ctx, chromedp.Location(&current))
	return current, err
}

// A step finds its element from page JavaScript, like the docs captures:
// chromedp's node waits read a DOM cache that can miss a subtree LiveView
// inserts after load (a dialog opened by a server event) and then never return.
// It also waits until the element is enabled (a confirm button the server
// enables after the typed value arrives) and is the one under its center
// point, so a click never lands on an overlay still fading out (a closing dialog).
const stepTargetScript = `(function(selector){const el=[...document.querySelectorAll(selector)].find(n=>n.checkVisibility());if(!el||el.disabled)return null;el.scrollIntoView({block:'center',inline:'center',behavior:'instant'});const b=el.getBoundingClientRect();const x=b.x+b.width/2,y=b.y+b.height/2;const hit=document.elementFromPoint(x,y);if(!hit||!el.contains(hit))return null;return [x,y]})`

// Passing the values as JSON also preserves empty strings, which the pinned
// CDP argument encoder otherwise omits in SetValue calls.
const fillScript = `(function(field){const input=[...document.querySelectorAll(field.Selector)].find(n=>n.checkVisibility());input.focus();input.value=field.Value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));input.blur();})`

func (s *Session) runStep(step Step) error {
	selector := step.Click
	if step.Fill != nil {
		selector = step.Fill.Selector
	}
	encoded, _ := json.Marshal(selector)
	ctx, cancel := context.WithTimeout(s.Context, 10*time.Second)
	defer cancel()
	var center []float64
	for {
		center = nil
		if err := chromedp.Run(ctx, chromedp.Evaluate(stepTargetScript+"("+string(encoded)+")", &center)); err == nil && len(center) == 2 {
			break
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("no visible, enabled, uncovered element matches %s: %w", selector, ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
	if step.Fill == nil {
		// A real mouse click at the element's center, so focus moves the way a
		// person's click moves it.
		return chromedp.Run(s.Context, chromedp.MouseClickXY(center[0], center[1]))
	}
	field, _ := json.Marshal(step.Fill)
	return chromedp.Run(s.Context, chromedp.Evaluate(fillScript+"("+string(field)+")", nil))
}

func (s *Session) Shot(options ShotOptions) ([]string, error) {
	if options.Width == 0 {
		options.Width = 1440
	}
	if options.Email == "" {
		options.Email = "demo@emisar.dev"
	}
	if err := s.Viewport(options.Width, 900, 1, false); err != nil {
		return nil, err
	}
	if err := s.Navigate(options.Path); err != nil {
		return nil, err
	}
	current, err := s.CurrentURL()
	if err != nil {
		return nil, err
	}
	if strings.Contains(current, "/sign_in") {
		if err := s.Login(options.Email); err != nil {
			return nil, err
		}
		if err := s.Navigate(options.Path); err != nil {
			return nil, err
		}
	}
	// A tab left behind the sign-in tab paints no frames, so requestAnimationFrame
	// never fires and a JS.show reveal (a dialog opened by a step) stays hidden.
	if len(options.Steps) > 0 {
		if err := chromedp.Run(s.Context, page.BringToFront()); err != nil {
			return nil, err
		}
	}
	for _, step := range options.Steps {
		if err := s.runStep(step); err != nil {
			return nil, err
		}
		if err := s.Ready(10*time.Second, ""); err != nil {
			return nil, err
		}
	}
	if options.Settle > 0 {
		time.Sleep(options.Settle)
	}
	full := filepath.Join(options.Out, options.Label+"-full.png")
	if err := s.FullScreenshot(full); err != nil {
		return nil, err
	}
	paths := []string{full}
	if options.Anchor != nil {
		const selector = `[data-shot-target="1"]`
		if err := s.MarkAnchor(*options.Anchor, "data-shot-target"); err != nil {
			return nil, fmt.Errorf("%w on %s", err, current)
		}
		if err := s.Ready(10*time.Second, selector); err != nil {
			return nil, err
		}
		crop := filepath.Join(options.Out, options.Label+"-crop.png")
		if err := s.ElementScreenshot(selector, crop, 2); err != nil {
			return nil, err
		}
		paths = append(paths, crop)
	}
	return paths, nil
}
