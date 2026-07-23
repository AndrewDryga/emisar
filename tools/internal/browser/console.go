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

type ConsoleConfig struct {
	BaseURL     string
	Email       string
	Slug        string
	Out         string
	DesktopWide int64
}

type manifestEntry struct {
	Name  string   `json:"name"`
	URL   *string  `json:"url"`
	Files []string `json:"files"`
	Note  string   `json:"note,omitempty"`
}

type namedPath struct{ Name, Path string }

var authPages = []namedPath{
	{"auth-sign-in", "/sign_in"},
	{"auth-sign-up", "/sign_up"},
	{"auth-magic-link", "/sign_in/magic"},
}

var consolePages = []namedPath{
	{"dashboard", ""}, {"runners", "/runners"}, {"runner-install", "/runners/install"},
	{"runs", "/runs"}, {"approvals", "/approvals"}, {"runbooks", "/runbooks"},
	{"runbook-new", "/runbooks/new"}, {"policies", "/policies"}, {"packs", "/packs"},
	{"audit", "/audit"}, {"audit-export", "/audit/export"}, {"runner-keys", "/runners/keys"},
	{"agents", "/agents"}, {"agents-connect", "/agents/connect"}, {"team", "/settings/team"},
	{"team-invite", "/settings/team/invite"}, {"sso", "/settings/sso"}, {"sso-new", "/settings/sso/new"},
	{"billing", "/settings/billing"}, {"profile", "/settings/profile"},
}

func shootConsole(session *Session, config ConsoleConfig, name, note string) (manifestEntry, error) {
	files := []string{}
	for _, viewport := range []struct {
		width, height int64
		mobile        bool
		label         string
	}{{config.DesktopWide, 900, false, "desktop"}, {390, 844, true, "mobile"}} {
		if err := session.Viewport(viewport.width, viewport.height, 1, viewport.mobile); err != nil {
			return manifestEntry{}, err
		}
		if err := session.Ready(10*time.Second, ""); err != nil {
			return manifestEntry{}, err
		}
		file := name + "-" + viewport.label + ".png"
		if err := session.FullScreenshot(filepath.Join(config.Out, file)); err != nil {
			return manifestEntry{}, err
		}
		files = append(files, file)
	}
	current, _ := session.CurrentURL()
	relative := strings.TrimPrefix(current, config.BaseURL)
	return manifestEntry{Name: name, URL: &relative, Files: files, Note: note}, nil
}

func navigateAndShoot(session *Session, config ConsoleConfig, name, target, note string) (manifestEntry, error) {
	if err := session.Navigate(target); err != nil {
		relative := strings.TrimPrefix(target, config.BaseURL)
		return manifestEntry{Name: name, URL: &relative, Note: "FAILED: " + err.Error()}, err
	}
	return shootConsole(session, config, name, note)
}

func findHref(session *Session, pattern, excluded string) (string, error) {
	patternJSON, _ := json.Marshal(pattern)
	excludedJSON, _ := json.Marshal(excluded)
	script := `(function(pattern,excluded){const re=new RegExp(pattern);const hit=[...document.querySelectorAll('a[href]')].find(a=>re.test(a.getAttribute('href'))&&(!excluded||!a.getAttribute('href').includes(excluded)));return hit?hit.getAttribute('href'):''})(` + string(patternJSON) + `,` + string(excludedJSON) + `)`
	var href string
	err := chromedp.Run(session.Context, chromedp.Evaluate(script, &href))
	return href, err
}

func CaptureConsole(ctx context.Context, manager *Manager, config ConsoleConfig) error {
	if config.Email == "" {
		config.Email = "demo@emisar.dev"
	}
	if config.Slug == "" {
		config.Slug = "demo"
	}
	if config.DesktopWide == 0 {
		config.DesktopWide = 1440
	}
	if err := os.MkdirAll(config.Out, 0o755); err != nil {
		return err
	}
	manifest := []manifestEntry{}
	failures := 0

	// Authentication pages must never inherit cookies from the persistent demo profile.
	auth, err := manager.Session(ctx, config.BaseURL, true)
	if err != nil {
		return err
	}
	fmt.Fprintln(manager.Out, "auth pages (signed out):")
	for _, item := range authPages {
		entry, shotErr := navigateAndShoot(auth, config, item.Name, item.Path, "")
		manifest = append(manifest, entry)
		if shotErr != nil {
			failures++
			fmt.Fprintf(manager.Err, "  x %s - %v\n", item.Name, shotErr)
		} else {
			fmt.Fprintf(manager.Out, "  %s\n", item.Name)
		}
	}
	auth.Close()

	session, err := manager.Session(ctx, config.BaseURL, false)
	if err != nil {
		return err
	}
	defer session.Close()
	if err := session.Navigate("/app/" + config.Slug); err != nil {
		return err
	}
	current, _ := session.CurrentURL()
	if strings.Contains(current, "/sign_in") {
		if err := session.Login(config.Email); err != nil {
			return err
		}
	}
	fmt.Fprintln(manager.Out, "console pages:")
	for _, item := range consolePages {
		entry, shotErr := navigateAndShoot(session, config, item.Name, "/app/"+config.Slug+item.Path, "")
		manifest = append(manifest, entry)
		if shotErr != nil {
			failures++
			fmt.Fprintf(manager.Err, "  x %s - %v\n", item.Name, shotErr)
		} else {
			fmt.Fprintf(manager.Out, "  %s\n", item.Name)
		}
	}

	details := []struct{ list, pattern, excluded, name string }{
		{"/runners", `/app/` + config.Slug + `/runners/[0-9a-f-]{36}$`, "", "runner-detail"},
		{"/runs", `/app/` + config.Slug + `/runs/`, "/new/", "run-detail"},
		{"/approvals", `/app/` + config.Slug + `/approvals/`, "", "approval-detail"},
		{"/runbooks", `/runbooks/[^/]+/edit$`, "", "runbook-edit"},
		{"/runbooks", `/runbooks/[^/]+/run$`, "", "runbook-run"},
		{"/settings/sso", `/app/` + config.Slug + `/settings/sso/`, "/new", "sso-detail"},
	}
	for _, detail := range details {
		if err := session.Navigate("/app/" + config.Slug + detail.list); err != nil {
			return err
		}
		href, err := findHref(session, detail.pattern, detail.excluded)
		if err != nil {
			return err
		}
		if href == "" {
			manifest = append(manifest, manifestEntry{Name: detail.name, Note: "skipped - no row on " + detail.list})
			fmt.Fprintf(manager.Out, "  %s (no row)\n", detail.name)
			continue
		}
		entry, shotErr := navigateAndShoot(session, config, detail.name, href, "")
		manifest = append(manifest, entry)
		if shotErr != nil {
			failures++
			fmt.Fprintf(manager.Err, "  x %s - %v\n", detail.name, shotErr)
		} else {
			fmt.Fprintf(manager.Out, "  %s\n", detail.name)
		}
	}

	if err := session.Navigate("/app/" + config.Slug + "/runners"); err != nil {
		return err
	}
	runnerHref, _ := findHref(session, `/app/`+config.Slug+`/runners/`, "/install")
	if runnerHref != "" {
		_ = session.Navigate(runnerHref)
		runHref, _ := findHref(session, `/runs/new/`, "")
		if runHref != "" {
			entry, shotErr := navigateAndShoot(session, config, "run-new", runHref, "")
			manifest = append(manifest, entry)
			if shotErr != nil {
				failures++
			}
		} else {
			manifest = append(manifest, manifestEntry{Name: "run-new", Note: "skipped - runner has no Run link"})
		}
	}

	if err := session.Navigate("/app/" + config.Slug + "/audit"); err == nil {
		if clickErr := chromedp.Run(session.Context, chromedp.Click("tbody tr", chromedp.ByQuery)); clickErr == nil {
			_ = session.Ready(10*time.Second, "")
			entry, shotErr := shootConsole(session, config, "audit-detail", "")
			manifest = append(manifest, entry)
			if shotErr != nil {
				failures++
			}
		} else {
			manifest = append(manifest, manifestEntry{Name: "audit-detail", Note: "skipped - no audit rows"})
		}
	}

	data, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(config.Out, "manifest.json"), append(data, '\n'), 0o644); err != nil {
		return err
	}
	if failures != 0 {
		return fmt.Errorf("%d console captures failed", failures)
	}
	fmt.Fprintf(manager.Out, "Wrote %d console entries to %s\n", len(manifest), config.Out)
	return nil
}
