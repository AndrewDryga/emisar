package browser

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

type DocsConfig struct {
	BaseURL string
	Email   string
	Temp    string
	Static  string
}

// shot is one docs screenshot: navigate Path, run any Clicks (reveal flows),
// then crop to Anchor at viewport Width, drop TopCSS top pixels, write Output.
type shot struct {
	Name   string
	Path   string
	Clicks []string
	Anchor Anchor
	Width  int // viewport CSS width; 0 → defaultWidth
	TopCSS int
	Output string
}

// The docs measure is ~672px, so a shot displays at ~40% of a 1680px desktop
// capture — text turns illegible. Capturing narrower renders the same feature
// LARGER in the column, and a sub-xl width also lets the how-keys/what-is help
// rails (xl-gated on connect + agents) stack off-crop, since the docs prose
// beside the image already teaches them.
const (
	defaultWidth = 1680
	docsWidth    = 1120
)

// clickText clicks the first button/link/[phx-click] whose trimmed text equals label.
func clickText(label string) string {
	return fmt.Sprintf(`(()=>{const b=[...document.querySelectorAll('button,a,[phx-click]')].find(x=>x.textContent.trim()===%q);if(b){b.click();return true}return false})()`, label)
}

// clickFirstEditLink opens a runbook's editor from the runbooks list.
const clickFirstEditLink = `(()=>{const a=document.querySelector('a[href*="/edit"]');if(a){a.click();return true}return false})()`

// clickSSOConnection opens an SSO connection's detail page from the team page.
const clickSSOConnection = `(()=>{const a=[...document.querySelectorAll('a[href*="/settings/sso/"]')].find(x=>/\/settings\/sso\/[0-9a-f-]{8,}/.test(x.getAttribute('href')));if(a){a.click();return true}return false})()`

// docsShots — one entry per docs screenshot, each cropped to the one feature
// its page teaches, at docsWidth unless the content genuinely needs more room.
var docsShots = []shot{
	{Name: "policy-editor", Path: "/app/demo/policies", Anchor: Anchor{Heading: "Default policy", Climb: "section"}, Width: docsWidth, Output: "screenshots/policy-editor.webp"},
	{Name: "audit-view", Path: "/app/demo/audit?event_type[]=group:Run", Anchor: Anchor{Selector: "#audit-events"}, Width: 1280, Output: "screenshots/audit-view.webp"},
	{Name: "runner-fleet", Path: "/app/demo/runners", Anchor: Anchor{Selector: "#runners"}, Width: docsWidth, Output: "screenshots/runner-fleet.webp"},
	{Name: "team-page", Path: "/app/demo/settings/team", Anchor: Anchor{Selector: "#members", Climb: "section"}, Width: docsWidth, Output: "screenshots/team-page.webp"},
	{Name: "sso-add-connection", Path: "/app/demo/settings/sso/new", Anchor: Anchor{Selector: "#provider_form"}, Width: docsWidth, Output: "docs/sso/sso-add-connection.webp"},
	{Name: "runs", Path: "/app/demo/runs", Anchor: Anchor{Selector: "#runs"}, Width: 1280, Output: "screenshots/runs.webp"},
	{Name: "agents", Path: "/app/demo/agents", Anchor: Anchor{Selector: "#agents"}, Width: docsWidth, Output: "screenshots/agents.webp"},
	// Connect form: click a cloud client to reveal the connector fields, then crop
	// to the form panel — #connect-panel excludes the how-keys-work rail beside it.
	{Name: "connect-llm-agents", Path: "/app/demo/agents/connect", Clicks: []string{clickText("Claude.ai")}, Anchor: Anchor{Selector: "#connect-panel"}, Width: docsWidth, Output: "screenshots/connect-llm-agents.webp"},
	// Same connect panel with a LOCAL/CLI client selected — the bridge + key setup.
	{Name: "connect-cli-agents", Path: "/app/demo/agents/connect", Clicks: []string{clickText("Claude Code")}, Anchor: Anchor{Selector: "#connect-panel"}, Width: docsWidth, Output: "screenshots/connect-cli-agents.webp"},
	// Runbook editor: open a seeded runbook and crop to its ordered, gated steps —
	// what a runbook IS, not two list rows.
	{Name: "runbooks", Path: "/app/demo/runbooks", Clicks: []string{clickFirstEditLink}, Anchor: Anchor{Selector: "#runbook-steps"}, Width: docsWidth, Output: "screenshots/runbooks.webp"},
	{Name: "sso-directory-sync", Path: "/app/demo/settings/team", Clicks: []string{clickSSOConnection}, Anchor: Anchor{Heading: "Directory sync (SCIM)", Climb: "section"}, Width: docsWidth, Output: "docs/sso/sso-directory-sync.webp"},
}

func (s shot) width() int {
	if s.Width == 0 {
		return defaultWidth
	}
	return s.Width
}

var rgbPattern = regexp.MustCompile(`\d+`)

func rgbHex(value string) string {
	parts := rgbPattern.FindAllString(value, 3)
	if len(parts) != 3 {
		return "#09090b"
	}
	result := "#"
	for _, part := range parts {
		number, _ := strconv.Atoi(part)
		result += fmt.Sprintf("%02x", number)
	}
	return result
}

func captureDocElement(session *Session, config DocsConfig, anchor Anchor, name string) (string, error) {
	if err := session.MarkAnchor(anchor, "data-shot"); err != nil {
		return "", fmt.Errorf("%s: %w", name, err)
	}
	const selector = `[data-shot="1"]`
	if err := session.Ready(10*time.Second, selector); err != nil {
		return "", err
	}
	path := filepath.Join(config.Temp, name+".png")
	if err := session.ElementScreenshot(selector, path, 2); err != nil {
		return "", err
	}
	var color string
	script := `(function(){let el=document.querySelector('[data-shot="1"]');while(el){const c=getComputedStyle(el).backgroundColor;if(c&&c!=='rgba(0, 0, 0, 0)'&&c!=='transparent')return c;el=el.parentElement;}return 'rgb(9, 9, 11)'})()`
	if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &color), chromedp.Evaluate(`document.querySelector('[data-shot="1"]')?.removeAttribute('data-shot')`, nil)); err != nil {
		return "", err
	}
	return rgbHex(color), nil
}

func imageCommand(tool string, args ...string) ([]byte, error) {
	if _, err := exec.LookPath("magick"); err == nil {
		if tool != "convert" {
			args = append([]string{tool}, args...)
		}
		return exec.Command("magick", args...).CombinedOutput()
	}
	return exec.Command(tool, args...).CombinedOutput()
}

func clickByScript(session *Session, script, label string) error {
	var clicked bool
	if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &clicked)); err != nil {
		return err
	}
	if !clicked {
		return fmt.Errorf("%s was not found", label)
	}
	return nil
}

// captureShot sets the shot's viewport, navigates, runs its reveal clicks, and
// crops to its anchor. Returns the cropped element's background color.
func captureShot(session *Session, config DocsConfig, s shot) (string, error) {
	if err := session.Viewport(int64(s.width()), 2800, 2, false); err != nil {
		return "", err
	}
	if err := session.Navigate(s.Path); err != nil {
		return "", err
	}
	for _, click := range s.Clicks {
		if err := clickByScript(session, click, s.Name); err != nil {
			return "", err
		}
		if err := session.Ready(10*time.Second, ""); err != nil {
			return "", err
		}
	}
	return captureDocElement(session, config, s.Anchor, s.Name)
}

// processShot converts a captured PNG into the bordered, resized webp, dropping
// TopCSS top pixels first when set.
func processShot(config DocsConfig, s shot, color string, out io.Writer) error {
	png := filepath.Join(config.Temp, s.Name+".png")
	destination := filepath.Join(config.Static, filepath.FromSlash(s.Output))
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	widthOutput, commandErr := imageCommand("identify", "-format", "%w", png)
	if commandErr != nil {
		return fmt.Errorf("identify %s: %w: %s", png, commandErr, widthOutput)
	}
	width := strings.TrimSpace(string(widthOutput))
	args := []string{png}
	if s.TopCSS != 0 {
		args = append(args, "-crop", fmt.Sprintf("%sx%d+0+0", width, s.TopCSS*2), "+repage")
	}
	args = append(args, "-resize", "1600x>", "-bordercolor", color, "-border", "40", "-quality", "82", destination)
	if output, commandErr := imageCommand("convert", args...); commandErr != nil {
		return fmt.Errorf("convert %s: %w: %s", s.Name, commandErr, bytes.TrimSpace(output))
	}
	fmt.Fprintf(out, "  -> %s\n", s.Output)
	return nil
}

func CaptureDocs(ctx context.Context, manager *Manager, config DocsConfig) error {
	if config.Email == "" {
		config.Email = "demo@emisar.dev"
	}
	for _, dir := range []string{config.Temp, config.Static} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	session, err := manager.Session(ctx, config.BaseURL, false)
	if err != nil {
		return err
	}
	defer session.Close()
	// Log in once at a default viewport; each shot sets its own width.
	if err := session.Viewport(defaultWidth, 2800, 2, false); err != nil {
		return err
	}
	if err := session.Navigate("/app/demo"); err != nil {
		return err
	}
	current, _ := session.CurrentURL()
	if !strings.Contains(current, "/app/") {
		if err := session.Login(config.Email); err != nil {
			return err
		}
	}

	// Capture each shot independently: one bad anchor skips its shot, never the run.
	colors := map[string]string{}
	var failed []string
	for _, s := range docsShots {
		color, captureErr := captureShot(session, config, s)
		if captureErr != nil {
			failed = append(failed, fmt.Sprintf("%s (%v)", s.Name, captureErr))
			fmt.Fprintf(manager.Out, "  SKIP %s: %v\n", s.Name, captureErr)
			continue
		}
		colors[s.Name] = color
		fmt.Fprintf(manager.Out, "  %s w=%d bg=%s\n", s.Name, s.width(), color)
	}

	for _, s := range docsShots {
		color, ok := colors[s.Name]
		if !ok {
			continue
		}
		if err := processShot(config, s, color, manager.Out); err != nil {
			return err
		}
	}
	if len(failed) > 0 {
		fmt.Fprintf(manager.Out, "  %d shot(s) skipped: %s\n", len(failed), strings.Join(failed, "; "))
	}
	return nil
}
