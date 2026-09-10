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

// frameContexts remembers the default execution context of every in-process
// frame and the contexts attached to this page's iframe targets.
type frameContexts struct {
	page      context.Context
	mu        sync.Mutex
	byFrame   map[cdp.FrameID]runtime.ExecutionContextID
	byContext map[runtime.ExecutionContextID]cdp.FrameID
	// One attached context per iframe target for the whole run: cancelling one
	// would close the frame's target, and the browser's own shutdown ends them.
	children map[target.ID]context.Context
}

// trackFrames starts recording contexts for ctx's target. Call it before the
// first navigation so no frame's context is missed.
func trackFrames(ctx context.Context) *frameContexts {
	contexts := &frameContexts{
		page:      ctx,
		byFrame:   map[cdp.FrameID]runtime.ExecutionContextID{},
		byContext: map[runtime.ExecutionContextID]cdp.FrameID{},
		children:  map[target.ID]context.Context{},
	}
	chromedp.ListenTarget(ctx, func(ev any) {
		switch ev := ev.(type) {
		case *runtime.EventExecutionContextCreated:
			var aux struct {
				FrameID   cdp.FrameID `json:"frameId"`
				IsDefault bool        `json:"isDefault"`
			}
			if err := json.Unmarshal(ev.Context.AuxData, &aux); err != nil || !aux.IsDefault {
				return
			}
			contexts.mu.Lock()
			contexts.byFrame[aux.FrameID] = ev.Context.ID
			contexts.byContext[ev.Context.ID] = aux.FrameID
			contexts.mu.Unlock()
		case *runtime.EventExecutionContextDestroyed:
			contexts.mu.Lock()
			if frame, ok := contexts.byContext[ev.ExecutionContextID]; ok && contexts.byFrame[frame] == ev.ExecutionContextID {
				delete(contexts.byFrame, frame)
			}
			delete(contexts.byContext, ev.ExecutionContextID)
			contexts.mu.Unlock()
		case *runtime.EventExecutionContextsCleared:
			contexts.mu.Lock()
			contexts.byFrame = map[cdp.FrameID]runtime.ExecutionContextID{}
			contexts.byContext = map[runtime.ExecutionContextID]cdp.FrameID{}
			contexts.mu.Unlock()
		}
	})
	return contexts
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
// page, nested ones included. A frame whose context has not been announced yet
// is skipped; the callers retry on their own schedule.
func (c *frameContexts) frames(ctx context.Context) ([]frame, error) {
	tree, err := page.GetFrameTree().Do(ctx)
	if err != nil {
		return nil, err
	}
	known := map[cdp.FrameID]bool{}
	var frames []frame
	c.mu.Lock()
	var walk func(node *page.FrameTree)
	walk = func(node *page.FrameTree) {
		known[node.Frame.ID] = true
		if id, ok := c.byFrame[node.Frame.ID]; ok {
			frames = append(frames, frame{context: id, url: node.Frame.URL})
		}
		for _, child := range node.ChildFrames {
			walk(child)
		}
	}
	walk(tree)
	c.mu.Unlock()

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
		return chromedp.Run(f.child, chromedp.Evaluate(script, res))
	}
	remote, exception, err := runtime.Evaluate(script).
		WithContextID(f.context).
		WithReturnByValue(true).
		Do(ctx)
	if err != nil {
		return err
	}
	if exception != nil {
		return exception
	}
	if res == nil || remote == nil || remote.Value == nil {
		return nil
	}
	return json.Unmarshal(remote.Value, res)
}

// firstFrame runs script in every frame until one returns true, reporting
// whether any did. Errors in a frame count as false: a frame mid-navigation or
// without a body is exactly the frame that does not hold what is being sought.
func (c *frameContexts) firstFrame(ctx context.Context, script string) (bool, error) {
	var found bool
	err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
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
	return chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
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
	err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
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
	_ = chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
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
	var buffer []byte
	if err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		params := page.CaptureScreenshot().WithFormat(page.CaptureScreenshotFormatPng)
		if clip != nil {
			params = params.WithClip(clip)
		}
		var err error
		buffer, err = params.Do(ctx)
		return err
	})); err != nil {
		return err
	}
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
