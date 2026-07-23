package devtool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
)

func (a *App) capture(ctx context.Context, args []string) error {
	if len(args) != 1 || (args[0] != "docs" && args[0] != "console") {
		return usage("usage: ./run capture <docs|console>")
	}
	manager, workspace, err := a.startBrowser(ctx)
	if err != nil {
		return err
	}
	switch args[0] {
	case "console":
		width, _ := strconv.ParseInt(os.Getenv("DESKTOP_WIDTH"), 10, 64)
		out := os.Getenv("OUT_DIR")
		if out == "" {
			out = filepath.Join(a.Root, "test-results", "console-audit")
		} else if !filepath.IsAbs(out) {
			out = filepath.Join(a.Root, out)
		}
		return devbrowser.CaptureConsole(ctx, manager, devbrowser.ConsoleConfig{
			BaseURL: workspace.PortalURL, Email: os.Getenv("EMAIL"), Slug: os.Getenv("ACCOUNT_SLUG"), Out: out, DesktopWide: width,
		})
	case "docs":
		port, _ := portFromURL(workspace.PortalURL)
		return devbrowser.CaptureDocs(ctx, manager, devbrowser.DocsConfig{
			BaseURL: workspace.PortalURL,
			Email:   os.Getenv("EMAIL"),
			Temp:    filepath.Join(a.cacheRoot(), fmt.Sprintf("docshots-%d", port)),
			Static:  filepath.Join(a.Portal, "apps", "emisar_web", "priv", "static", "images"),
		})
	}
	return nil
}
