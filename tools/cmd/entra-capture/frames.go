package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/cdproto/runtime"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
)

// Azure renders each blade extension in its OWN cross-origin IFRAME — a React
// blade served from reactblade.portal.azure.net. That is why the top document's
// text reads as the home shell while the screenshot plainly shows a form, and
// why a top-level query finds the surrounding navigation and none of the
// toolbar a step names. Chrome isolates those frames into their own renderer
// and their own DevTools target, so chromedp's page context never sees them:
// its frame tree lists no child, and their scripts have to run through a
// context attached to the iframe's target. The helpers here run a script in
// every frame — the way Playwright's page.frames() did — over both kinds: the
// page's own in-process frames by execution context, and the out-of-process
// blades by attached target, scoped to this page through each target's parent
// frame.

// frameContexts keeps one attached context per out-of-process iframe target.
// In-process frames are discovered from the current frame tree on each scan.
type frameContexts struct {
	page     context.Context
	mu       sync.Mutex
	children map[target.ID]context.Context
}

func trackFrames(ctx context.Context) *frameContexts {
	return &frameContexts{page: ctx, children: map[target.ID]context.Context{}}
}

// A frame is one place a script can run: an in-process frame addressed by its
// execution context, or an out-of-process iframe addressed by its own context.
type frame struct {
	context runtime.ExecutionContextID
	child   context.Context
	url     string
}

// frames lists the page's frames: the top document and its in-process children
// in tree order, then every isolated iframe whose parent frame belongs to this
// page, nested ones included. Frames that disappear during the scan are skipped;
// callers retry on their own schedule.
func (c *frameContexts) frames(ctx context.Context) ([]frame, error) {
	tree, err := chromedp.Call(ctx, page.GetFrameTree, cdp.Empty{})
	if err != nil {
		return nil, err
	}
	known := map[cdp.FrameID]bool{}
	var frames []frame
	var walk func(node *page.FrameTree)
	walk = func(node *page.FrameTree) {
		known[node.Frame.ID] = true
		// These helpers read and interact with DOM, so a named isolated world
		// provides an authoritative context without racing context lifecycle events.
		world, err := chromedp.Call(ctx, page.CreateIsolatedWorld, page.CreateIsolatedWorldParams{FrameID: node.Frame.ID, WorldName: "emisar-entra-capture"})
		if err == nil {
			frames = append(frames, frame{context: world.ExecutionContextID, url: node.Frame.URL})
		}
		for _, child := range node.ChildFrames {
			walk(child)
		}
	}
	walk(tree.FrameTree)

	targets, err := chromedp.Targets(c.page)
	if err != nil {
		return nil, err
	}
	// A blade can nest another blade's iframe, so keep adopting targets until
	// no target's parent is a frame adopted in the previous pass.
	for adopted := true; adopted; {
		adopted = false
		for _, info := range targets {
			if info.Type != "iframe" || !known[info.ParentFrameID] || known[cdp.FrameID(info.TargetID)] {
				continue
			}
			known[cdp.FrameID(info.TargetID)] = true
			adopted = true
			frames = append(frames, frame{child: c.attach(info.TargetID), url: info.URL})
		}
	}
	return frames, nil
}

func (c *frameContexts) attach(id target.ID) context.Context {
	c.mu.Lock()
	defer c.mu.Unlock()
	if child, ok := c.children[id]; ok {
		return child
	}
	child, _ := chromedp.NewContext(c.page, chromedp.WithTargetID(id))
	c.children[id] = child
	return child
}

// evaluate runs script in one frame and decodes its value.
func (f frame) evaluate(ctx context.Context, script string, res any) error {
	if f.child != nil {
		value, err := chromedp.Run(f.child, chromedp.Evaluate[[]byte](script))
		if err != nil {
			return err
		}
		if res == nil {
			return nil
		}
		return json.Unmarshal(value, res)
	}
	result, err := chromedp.Call(ctx, runtime.Evaluate, runtime.EvaluateParams{Expression: script, ContextID: f.context, ReturnByValue: new(true)})
	if err != nil {
		return err
	}
	if result.ExceptionDetails != nil {
		return fmt.Errorf("evaluating frame: %s", result.ExceptionDetails.Text)
	}
	if res == nil || result.Result == nil || result.Result.Value == nil {
		return nil
	}
	return json.Unmarshal(result.Result.Value, res)
}

// firstFrame runs script in every frame until one returns true, reporting
// whether any did. Errors in a frame count as false: a frame mid-navigation or
// without a body is exactly the frame that does not hold what is being sought.
func (c *frameContexts) firstFrame(ctx context.Context, script string) (bool, error) {
	var found bool
	err := chromedp.Do(ctx, chromedp.Func(func(ctx context.Context, _ *chromedp.Target) error {
		frames, err := c.frames(ctx)
		if err != nil {
			return err
		}
		for _, f := range frames {
			var ok bool
			if err := f.evaluate(ctx, script, &ok); err == nil && ok {
				found = true
				return nil
			}
		}
		return nil
	}))
	return found, err
}

// everyFrame runs script in every frame, ignoring per-frame failures.
func (c *frameContexts) everyFrame(ctx context.Context, script string) error {
	return chromedp.Do(ctx, chromedp.Func(func(ctx context.Context, _ *chromedp.Target) error {
		frames, err := c.frames(ctx)
		if err != nil {
			return err
		}
		for _, f := range frames {
			_ = f.evaluate(ctx, script, nil)
		}
		return nil
	}))
}

// frameTexts returns each frame's body text, top document first.
func (c *frameContexts) frameTexts(ctx context.Context) ([]frameText, error) {
	var texts []frameText
	err := chromedp.Do(ctx, chromedp.Func(func(ctx context.Context, _ *chromedp.Target) error {
		frames, err := c.frames(ctx)
		if err != nil {
			return err
		}
		for _, f := range frames {
			var info frameText
			if err := f.evaluate(ctx, `({url: location.href, text: document.body ? document.body.innerText : ""})`, &info); err != nil {
				continue
			}
			info.frame = f
			texts = append(texts, info)
		}
		return nil
	}))
	return texts, err
}

type frameText struct {
	frame frame
	URL   string `json:"url"`
	Text  string `json:"text"`
}

// describeFrames prints every frame's URL and the start of its text, so a
// blade that rendered in an iframe is diagnosed as one rather than as a page
// that never loaded.
func (c *frameContexts) describeFrames(ctx context.Context) {
	texts, err := c.frameTexts(ctx)
	if err != nil {
		fmt.Println("  frames: ", err)
		return
	}
	fmt.Println("--- frames ---")
	for _, frame := range texts {
		text := strings.Join(strings.Fields(frame.Text), " ")
		if len(text) > 300 {
			text = text[:300]
		}
		fmt.Printf("  %s\n    %s\n", frame.URL, text)
	}
}

// visibleControls lists the short labels of the last frame's controls, so a
// missed outline is diagnosed from the real blade rather than another guess.
func (c *frameContexts) visibleControls(ctx context.Context) []string {
	const script = `[...document.querySelectorAll('button,[role=button],[role=menuitem],a')]
      .filter(el => (el.offsetWidth > 0 || el.offsetHeight > 0))
      .map(el => (el.textContent || el.getAttribute('aria-label') || '').trim())
      .filter(text => text && text.length < 40)
      .slice(0, 40)`
	var labels []string
	_ = chromedp.Do(ctx, chromedp.Func(func(ctx context.Context, _ *chromedp.Target) error {
		frames, err := c.frames(ctx)
		if err != nil || len(frames) == 0 {
			return nil
		}
		_ = frames[len(frames)-1].evaluate(ctx, script, &labels)
		return nil
	}))
	sort.Strings(labels)
	return labels
}

// shot writes a viewport PNG, optionally clipped — a clip trims the portal's
// title bar, which no guide image includes.
func shot(ctx context.Context, outDir, name string, clip *page.Viewport) error {
	result, err := chromedp.Call(ctx, page.CaptureScreenshot, page.CaptureScreenshotParams{Format: page.CaptureScreenshotFormatPng, Clip: clip})
	if err != nil {
		return err
	}
	buffer := result.Data
	// 0600: these are captures of a live IdP console, so they stay owner-only
	// like the credential files the same run reads.
	if err := os.WriteFile(filepath.Join(outDir, name+".png"), buffer, 0o600); err != nil {
		return err
	}
	fmt.Println("  shot", name)
	return nil
}

// belowTitleBar clips the 42px portal title bar off a shot of the given width.
func belowTitleBar(width float64) *page.Viewport {
	return &page.Viewport{X: 0, Y: 42, Width: width, Height: 900, Scale: 1}
}
