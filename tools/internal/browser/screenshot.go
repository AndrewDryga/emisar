package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

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
	// Clicks run in order after navigation, each waiting for its selector —
	// how a shot reaches state behind a reveal (expand a step, then open its
	// picker), mirroring the docs captures' Clicks.
	Clicks []string
	Fills  []FieldFill
	Anchor *Anchor
}

// FieldFill replaces an input after the clicks have opened its form.
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

func (s *Session) FullScreenshot(path string) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, chromedp.FullScreenshot(&image, 100)); err != nil {
		return err
	}
	return writeImage(path, image)
}

func (s *Session) ViewportScreenshot(path string) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, chromedp.CaptureScreenshot(&image)); err != nil {
		return err
	}
	return writeImage(path, image)
}

func (s *Session) ElementScreenshot(selector, path string, scale float64) error {
	ctx, cancel := context.WithTimeout(s.Context, 20*time.Second)
	defer cancel()
	var image []byte
	if err := chromedp.Run(ctx, chromedp.ScreenshotScale(selector, scale, &image, chromedp.ByQuery)); err != nil {
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
	for _, click := range options.Clicks {
		if err := chromedp.Run(s.Context,
			chromedp.WaitVisible(click, chromedp.ByQuery),
			chromedp.Click(click, chromedp.ByQuery),
		); err != nil {
			return nil, err
		}
		if err := s.Ready(10*time.Second, ""); err != nil {
			return nil, err
		}
	}
	for _, fill := range options.Fills {
		encoded, _ := json.Marshal(fill)
		// Passing the values as JSON also preserves empty strings, which the
		// pinned CDP argument encoder otherwise omits in SetValue calls.
		setValue := `(function(field){const input=document.querySelector(field.Selector);input.value=field.Value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));})(` + string(encoded) + `)`
		if err := chromedp.Run(s.Context,
			chromedp.WaitVisible(fill.Selector, chromedp.ByQuery),
			chromedp.Focus(fill.Selector, chromedp.ByQuery),
			chromedp.Evaluate(setValue, nil),
			chromedp.Blur(fill.Selector, chromedp.ByQuery),
		); err != nil {
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
