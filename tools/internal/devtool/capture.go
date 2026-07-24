package devtool

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
)

func (a *App) capture(ctx context.Context, args []string) error {
	if len(args) == 0 || (args[0] != "docs" && args[0] != "console") {
		return usage("usage: ./run capture docs [shot...] | ./run capture console [--task ID] [--group NAME]")
	}
	consoleTask := screenshotTask{}
	consoleOut := ""
	if args[0] == "console" {
		flags := flag.NewFlagSet("capture console", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		taskID, group := "", "console-audit"
		flags.StringVar(&taskID, "task", "", "")
		flags.StringVar(&group, "group", group, "")
		if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
			return usage("usage: ./run capture console [--task ID] [--group NAME]")
		}
		var err error
		consoleTask, consoleOut, err = a.screenshotOutput(taskID, group)
		if err != nil {
			return err
		}
	}
	manager, workspace, err := a.startBrowser(ctx)
	if err != nil {
		return err
	}
	switch args[0] {
	case "console":
		fmt.Fprintf(a.Out, "screenshot task %s -> %s\n", consoleTask.ID, consoleOut)
		width, _ := strconv.ParseInt(os.Getenv("DESKTOP_WIDTH"), 10, 64)
		return devbrowser.CaptureConsole(ctx, manager, devbrowser.ConsoleConfig{
			BaseURL: workspace.PortalURL, Email: os.Getenv("EMAIL"), Slug: os.Getenv("ACCOUNT_SLUG"), Out: consoleOut, DesktopWide: width,
		})
	case "docs":
		port, _ := portFromURL(workspace.PortalURL)
		return devbrowser.CaptureDocs(ctx, manager, devbrowser.DocsConfig{
			BaseURL: workspace.PortalURL,
			Email:   os.Getenv("EMAIL"),
			Temp:    filepath.Join(a.cacheRoot(), fmt.Sprintf("docshots-%d", port)),
			Static:  filepath.Join(a.Portal, "apps", "emisar_web", "priv", "static", "images"),
			Only:    args[1:],
		})
	}
	return nil
}
