package browser

import (
	"bytes"
	"context"
	"fmt"
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

type docShot struct {
	Name   string
	Output string
	TopCSS int
}

var docShots = []docShot{
	{"policy-editor", "screenshots/policy-editor.webp", 0},
	{"audit-view", "screenshots/audit-view.webp", 1180},
	{"runbooks", "screenshots/runbooks.webp", 0},
	{"runner-fleet", "screenshots/runner-fleet.webp", 0},
	{"team-page", "screenshots/team-page.webp", 0},
	{"sso-add-connection", "docs/sso/sso-add-connection.webp", 850},
	{"sso-directory-sync", "docs/sso/sso-directory-sync.webp", 0},
	{"connect-llm-agents", "screenshots/connect-llm-agents.webp", 820},
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
	if err := session.Viewport(1680, 2800, 2, false); err != nil {
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
	colors := map[string]string{}
	crop := func(path string, anchor Anchor, name string) error {
		if err := session.Navigate(path); err != nil {
			return err
		}
		color, cropErr := captureDocElement(session, config, anchor, name)
		if cropErr == nil {
			colors[name] = color
			fmt.Fprintf(manager.Out, "  %s bg=%s\n", name, color)
		}
		return cropErr
	}
	steps := []struct {
		path   string
		anchor Anchor
		name   string
	}{
		{"/app/demo/policies", Anchor{Heading: "Default policy", Climb: "section"}, "policy-editor"},
		{"/app/demo/audit?event_type[]=group:Run", Anchor{Selector: "#audit-events", Climb: ".space-y-4"}, "audit-view"},
		{"/app/demo/runbooks", Anchor{Selector: "#runbooks"}, "runbooks"},
		{"/app/demo/runners", Anchor{Selector: "#runners"}, "runner-fleet"},
		{"/app/demo/settings/team", Anchor{Selector: "#members", Climb: "section"}, "team-page"},
		{"/app/demo/settings/sso/new", Anchor{Selector: "#provider_form"}, "sso-add-connection"},
	}
	for _, step := range steps {
		if err := crop(step.path, step.anchor, step.name); err != nil {
			return err
		}
	}
	if err := session.Navigate("/app/demo/settings/team"); err != nil {
		return err
	}
	if err := clickByScript(session, `(()=>{const a=[...document.querySelectorAll('a[href*="/settings/sso/"]')].find(x=>/\/settings\/sso\/[0-9a-f-]{8,}/.test(x.getAttribute('href')));if(a){a.click();return true}return false})()`, "SSO connection link"); err != nil {
		return err
	}
	if err := session.Ready(10*time.Second, ""); err != nil {
		return err
	}
	color, err := captureDocElement(session, config, Anchor{Heading: "Directory sync (SCIM)", Climb: "section"}, "sso-directory-sync")
	if err != nil {
		return err
	}
	colors["sso-directory-sync"] = color
	if err := session.Navigate("/app/demo/agents/connect"); err != nil {
		return err
	}
	if err := clickByScript(session, `(()=>{const b=[...document.querySelectorAll('button,a,[phx-click]')].find(x=>x.textContent.trim()==='Claude.ai');if(b){b.click();return true}return false})()`, "Claude.ai integration control"); err != nil {
		return err
	}
	if err := session.Ready(10*time.Second, ""); err != nil {
		return err
	}
	color, err = captureDocElement(session, config, Anchor{ClassContains: []string{"grid-cols-[minmax(0,1fr)_22rem]", "gap-x-16"}}, "connect-llm-agents")
	if err != nil {
		return err
	}
	colors["connect-llm-agents"] = color

	for _, shot := range docShots {
		png := filepath.Join(config.Temp, shot.Name+".png")
		destination := filepath.Join(config.Static, filepath.FromSlash(shot.Output))
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return err
		}
		widthOutput, commandErr := imageCommand("identify", "-format", "%w", png)
		if commandErr != nil {
			return fmt.Errorf("identify %s: %w: %s", png, commandErr, widthOutput)
		}
		width := strings.TrimSpace(string(widthOutput))
		args := []string{png}
		if shot.TopCSS != 0 {
			args = append(args, "-crop", fmt.Sprintf("%sx%d+0+0", width, shot.TopCSS*2), "+repage")
		}
		args = append(args, "-resize", "1600x>", "-bordercolor", colors[shot.Name], "-border", "40", "-quality", "82", destination)
		if output, commandErr := imageCommand("convert", args...); commandErr != nil {
			return fmt.Errorf("convert %s: %w: %s", shot.Name, commandErr, bytes.TrimSpace(output))
		}
		fmt.Fprintf(manager.Out, "  -> %s\n", shot.Output)
	}
	return nil
}
