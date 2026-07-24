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
	// Only limits the run to the named shots (all when empty) — fast iteration
	// on one capture without rewriting every committed image.
	Only []string
}

// shot is one docs screenshot: navigate Path, run any Clicks (reveal flows),
// then crop to Anchor at viewport Width, keep only the top TopCSS CSS pixels (or
// the header + first Rows RowSelector rows) when set, write Output.
type shot struct {
	Name string
	Path string
	// Clicks run in order after navigation to reveal a flow before the crop.
	Clicks []string
	Anchor Anchor
	Width  int // viewport CSS width; 0 → defaultWidth
	TopCSS int // keep only the top N CSS pixels of the anchor (0 → whole anchor)
	// Rows + RowSelector cap a long list: hide every RowSelector row past the
	// first Rows before the shot, so the anchor shrinks to its header + those rows
	// and the tail falls away. RowSelector matches document-wide.
	Rows        int
	RowSelector string
	Output      string
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

// clickRowLink clicks the first link matching a CSS selector whose row (or the
// link itself) contains the given text — list order is presentation, content is
// the contract (e.g. "the pending caddy.reload_config row", wherever it sorts).
func clickRowLink(selector, contains string) string {
	return fmt.Sprintf(`(()=>{const b=[...document.querySelectorAll(%q)].find(a=>((a.closest('li,tr')||a).textContent||'').includes(%q));if(b){b.click();return true}return false})()`, selector, contains)
}

// clickFirstEditLink opens a runbook's editor from the runbooks list.
const clickFirstEditLink = `(()=>{const a=document.querySelector('a[href*="/edit"]');if(a){a.click();return true}return false})()`

// collapseAuditFilters folds the audit facet drawer (it arrives expanded when
// the URL carries a filter). Self-verifying: reports success only once
// aria-expanded flips, so a click against the dead pre-connect render (which
// does nothing) is retried instead of trusted.
const collapseAuditFilters = `(()=>{const b=document.querySelector('button[phx-click="toggle_filters"]');if(!b)return false;if(b.getAttribute('aria-expanded')==='false')return true;b.click();return false})()`

// clickSSOConnection opens an SSO connection's detail page from the team page.
const clickSSOConnection = `(()=>{const a=[...document.querySelectorAll('a[href*="/settings/sso/"]')].find(x=>/\/settings\/sso\/[0-9a-f-]{8,}/.test(x.getAttribute('href')));if(a){a.click();return true}return false})()`

// docsShots — one entry per docs screenshot, each cropped to the one feature
// its page teaches, at docsWidth unless the content genuinely needs more room.
var docsShots = []shot{
	{Name: "policy-editor", Path: "/app/demo/policies", Anchor: Anchor{Heading: "Default policy", Climb: "section"}, Width: docsWidth, Output: "screenshots/policy-editor.webp"},
	{Name: "audit-view", Path: "/app/demo/audit?event_type[]=group:Run", Anchor: Anchor{Selector: "#audit-events"}, Width: 1280, Output: "screenshots/audit-view.webp"},
	{Name: "runner-fleet", Path: "/app/demo/runners", Anchor: Anchor{Selector: "#runners"}, Width: docsWidth, Output: "screenshots/runner-fleet.webp"},
	// The full roster runs long; the teams-and-access page only needs to show the
	// shape of a member row, so keep the header + the first 4 (the directory-synced
	// members sort to the top) and let the tail fall off-crop.
	{Name: "team-page", Path: "/app/demo/settings/team", Anchor: Anchor{Selector: "#members", Climb: "section"}, Width: docsWidth, Rows: 4, RowSelector: "#members li", Output: "screenshots/team-page.webp"},
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
	// The /security "approval loop" cast — four uniform frames of ONE seeded
	// story (caddy.reload_config on edge-fra-01, requested by Maya via Claude,
	// approved by Jordan; seeds.exs pins the timings so the audit trail reads
	// causally). #shell-canvas is the console page without the nav rail;
	// TopCSS keeps every frame the same 1280x860 box so the cast can crossfade
	// without reflow. Capture preconditions: a FRESH `./run reset --seed`
	// (seeded pending approvals expire 24h after seeding) and a live
	// edge-fra-01 runner adopted by this portal — run the dev runner image
	// with EMISAR_URL pointed at this workspace and the fixed dev enrollment
	// key (seed with EMISAR_DEV_FIXED_ENROLLMENT_KEY set) — so the Decide rail
	// shows no runner-offline notice. Newest #pending row = the agent's caddy
	// reload; newest #decided row = the same action approved.
	{Name: "loop-approval-pending", Path: "/app/demo/approvals", Clicks: []string{clickRowLink(`#pending a[href*="/approvals/"]`, "caddy.reload_config")}, Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 860, Output: "screenshots/loop/approval-pending.webp"},
	{Name: "loop-approval-approved", Path: "/app/demo/approvals", Clicks: []string{clickRowLink(`#decided a[href*="/approvals/"]`, "caddy.reload_config")}, Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 860, Output: "screenshots/loop/approval-approved.webp"},
	{Name: "loop-run-success", Path: "/app/demo/approvals", Clicks: []string{clickRowLink(`#decided a[href*="/approvals/"]`, "caddy.reload_config"), clickText("View run")}, Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 860, Output: "screenshots/loop/run-success.webp"},
	// The Run + Approval groups together are the loop's trail; the folded
	// drawer still narrates them ("Filters — Type: …"), so the narrowing stays
	// visible while the frame is the timeline itself.
	{Name: "loop-audit-trail", Path: "/app/demo/audit?event_type[]=group:Run&event_type[]=group:Approval", Clicks: []string{collapseAuditFilters}, Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 860, Rows: 11, RowSelector: "#audit-events li", Output: "screenshots/loop/audit-trail.webp"},
}

func (s shot) width() int {
	if s.Width == 0 {
		return defaultWidth
	}
	return s.Width
}

// selectShots resolves the --only names against docsShots; an unknown name is
// an error (a typo silently capturing nothing would read as success).
func selectShots(only []string) ([]shot, error) {
	if len(only) == 0 {
		return docsShots, nil
	}
	byName := map[string]shot{}
	for _, s := range docsShots {
		byName[s.Name] = s
	}
	selected := make([]shot, 0, len(only))
	for _, name := range only {
		s, ok := byName[name]
		if !ok {
			return nil, fmt.Errorf("unknown docs shot %q (see docsShots in tools/internal/browser/docs.go)", name)
		}
		selected = append(selected, s)
	}
	return selected, nil
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

func captureDocElement(session *Session, config DocsConfig, s shot) (string, error) {
	const selector = `[data-shot="1"]`
	// Mark + settle, twice if needed: when a reveal click's LiveView navigation
	// lands AFTER the first mark, the marked node detaches (the layout re-renders)
	// and the settle loop can never see it again — re-marking finds the live node.
	settled := false
	for attempt := 0; attempt < 2 && !settled; attempt++ {
		if err := session.MarkAnchor(s.Anchor, "data-shot"); err != nil {
			return "", fmt.Errorf("%s: %w", s.Name, err)
		}
		// A long list (the member roster) makes the anchor far taller than the shot
		// needs — and past a point the element screenshot clips its top. Hide the rows
		// past Rows so the anchor shrinks to its header + the first Rows rows before
		// it settles and is shot; the tail simply doesn't render.
		if s.Rows > 0 && s.RowSelector != "" {
			hide := fmt.Sprintf(`(function(){const rows=document.querySelectorAll(%q);for(let i=%d;i<rows.length;i++)rows[i].style.display='none';return true})()`, s.RowSelector, s.Rows)
			if err := chromedp.Run(session.Context, chromedp.Evaluate(hide, nil)); err != nil {
				return "", err
			}
		}
		switch err := session.Ready(10*time.Second, selector); {
		case err == nil:
			settled = true
		case attempt == 1:
			return "", err
		}
	}
	path := filepath.Join(config.Temp, s.Name+".png")
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

// clickByScript retries while the target is missing: a prior click's LiveView
// navigation may still be in flight (Ready can't observe it), so the element
// this click wants often exists only a beat later.
func clickByScript(session *Session, script, label string) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		var clicked bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &clicked)); err != nil {
			return err
		}
		if clicked {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s was not found", label)
		}
		time.Sleep(500 * time.Millisecond)
	}
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
	return captureDocElement(session, config, s)
}

// processShot converts a captured PNG into the bordered, resized webp, keeping
// only the top TopCSS CSS pixels first when set.
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
		// Crop to the top TopCSS CSS pixels AND pad a shorter capture out to that
		// exact height, so every TopCSS shot in a set (the loop cast frames) has
		// identical dimensions regardless of each page's natural height. The crop
		// height derives from the captured width (not an assumed device scale):
		// the element renders at width()-CSS wide whatever the effective pixel
		// density, so width_px * TopCSS / width() is scale-independent.
		pixels, atoiErr := strconv.Atoi(width)
		if atoiErr != nil {
			return fmt.Errorf("identify %s: unexpected width %q", png, width)
		}
		box := fmt.Sprintf("%dx%d", pixels, pixels*s.TopCSS/s.width())
		args = append(args, "-crop", box+"+0+0", "+repage", "-background", color, "-extent", box)
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

	shots, err := selectShots(config.Only)
	if err != nil {
		return err
	}

	// Capture each shot independently: one bad anchor skips its shot, never the run.
	colors := map[string]string{}
	var failed []string
	for _, s := range shots {
		color, captureErr := captureShot(session, config, s)
		if captureErr != nil {
			failed = append(failed, fmt.Sprintf("%s (%v)", s.Name, captureErr))
			fmt.Fprintf(manager.Out, "  SKIP %s: %v\n", s.Name, captureErr)
			continue
		}
		colors[s.Name] = color
		fmt.Fprintf(manager.Out, "  %s w=%d bg=%s\n", s.Name, s.width(), color)
	}

	for _, s := range shots {
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
