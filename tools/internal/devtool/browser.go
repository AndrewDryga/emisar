package devtool

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
)

func (a *App) browserManager(ctx context.Context) (*devbrowser.Manager, Workspace, error) {
	workspace, err := a.loadWorkspace(ctx)
	if err != nil {
		return nil, Workspace{}, err
	}
	port, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return nil, Workspace{}, err
	}
	spki, err := a.tlsSPKI()
	if err != nil {
		return nil, Workspace{}, err
	}
	root := browserCacheRoot(a.cacheRoot(), a.Root, port)
	if err := os.MkdirAll(filepath.Dir(root), 0o700); err != nil {
		return nil, Workspace{}, err
	}
	manager := devbrowser.New(devbrowser.Config{
		State:   root + ".json",
		Profile: root + "-profile",
		Marker:  filepath.Join(root+"-profile", ".emisar-tls-spki"),
		Log:     root + ".log",
		SPKI:    spki,
		InBox:   a.inBox(),
		Out:     a.Out,
		Err:     a.Err,
	})
	return manager, workspace, nil
}

func browserCacheRoot(cache, workspace string, port int) string {
	canonical, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		canonical = workspace
	}
	identity := fmt.Sprintf("%x", sha256sum(canonical))[:12]
	return filepath.Join(cache, "browser-"+identity+"-"+strconv.Itoa(port))
}

func (a *App) ensureBrowser() error {
	chrome, err := devbrowser.ResolveChrome()
	if err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "browser available at %s\n", chrome)
	return nil
}

func (a *App) ensureImageTools() error {
	if _, err := exec.LookPath("magick"); err == nil {
		return nil
	}
	for _, command := range []string{"identify", "convert"} {
		if _, err := exec.LookPath(command); err != nil {
			return fmt.Errorf("ImageMagick is required for documentation captures (missing %s)", command)
		}
	}
	return nil
}

func (a *App) startBrowser(ctx context.Context) (*devbrowser.Manager, Workspace, error) {
	manager, workspace, err := a.browserManager(ctx)
	if err != nil {
		return nil, Workspace{}, err
	}
	binary, err := os.Executable()
	if err != nil {
		return nil, Workspace{}, err
	}
	state, err := manager.Start(ctx, binary)
	if err != nil {
		return nil, Workspace{}, err
	}
	fmt.Fprintf(a.Out, "browser ready (pid %d)\n", state.BrowserPID)
	return manager, workspace, nil
}

func (a *App) browserCommand(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return usage("usage: dev/run browser <start|stop|status>")
	}
	switch args[0] {
	case "start":
		_, _, err := a.startBrowser(ctx)
		return err
	case "stop":
		manager, _, err := a.browserManager(ctx)
		if err != nil {
			return err
		}
		if err := manager.Stop(ctx); err != nil {
			return err
		}
		fmt.Fprintln(a.Out, "browser stopped")
		return nil
	case "status":
		manager, _, err := a.browserManager(ctx)
		if err != nil {
			return err
		}
		state, err := manager.State()
		if err != nil {
			return fmt.Errorf("stopped")
		}
		fmt.Fprintf(a.Out, "running (pid %d)\n", state.BrowserPID)
		return nil
	default:
		return usage("usage: dev/run browser <start|stop|status>")
	}
}

func parseShot(args []string, root string) (devbrowser.ShotOptions, error) {
	options := devbrowser.ShotOptions{Out: filepath.Join(root, ".agent", "screenshots", "scratch"), Width: 1440}
	flags := flag.NewFlagSet("shot", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	shot, selector, heading, classContains, climb := "", "", "", "", ""
	settle := 0
	flags.StringVar(&options.Label, "label", "", "")
	flags.StringVar(&options.Out, "out", options.Out, "")
	flags.StringVar(&shot, "shot", "", "")
	flags.StringVar(&selector, "select", "", "")
	flags.StringVar(&heading, "heading", "", "")
	flags.StringVar(&classContains, "class-contains", "", "")
	flags.StringVar(&climb, "climb", "", "")
	flags.StringVar(&options.Click, "click", "", "")
	flags.Int64Var(&options.Width, "width", 1440, "")
	flags.IntVar(&settle, "settle", 0, "")
	path := ""
	flagArgs := make([]string, 0, len(args))
	for index := 0; index < len(args); index++ {
		if !strings.HasPrefix(args[index], "--") && path == "" {
			path = args[index]
			continue
		}
		flagArgs = append(flagArgs, args[index])
		if strings.HasPrefix(args[index], "--") && !strings.Contains(args[index], "=") && index+1 < len(args) {
			index++
			flagArgs = append(flagArgs, args[index])
		}
	}
	if err := flags.Parse(flagArgs); err != nil || path == "" || options.Label == "" || flags.NArg() != 0 {
		return options, usage("usage: dev/run shot <path> --label <before|after> [--shot NAME|--select CSS|--heading TEXT|--class-contains a,b] [--climb SEL] [--click SEL] [--width N] [--settle MS] [--out DIR]")
	}
	options.Path = path
	options.Settle = time.Duration(settle) * time.Millisecond
	if shot != "" {
		selector = `[data-shot='` + strings.ReplaceAll(shot, `'`, `\'`) + `']`
	}
	if selector != "" || heading != "" || classContains != "" {
		options.Anchor = &devbrowser.Anchor{Selector: selector, Heading: heading, Climb: climb}
		if classContains != "" {
			options.Anchor.ClassContains = strings.Split(classContains, ",")
		}
	}
	if !filepath.IsAbs(options.Out) {
		options.Out = filepath.Join(root, options.Out)
	}
	return options, nil
}

func (a *App) shot(ctx context.Context, args []string) error {
	options, err := parseShot(args, a.Root)
	if err != nil {
		return err
	}
	manager, workspace, err := a.startBrowser(ctx)
	if err != nil {
		return err
	}
	session, err := manager.Session(ctx, workspace.PortalURL, false)
	if err != nil {
		return err
	}
	defer session.Close()
	paths, err := session.Shot(options)
	if err != nil {
		return err
	}
	for _, path := range paths {
		fmt.Fprintln(a.Out, path)
	}
	return nil
}

func (a *App) browserDaemon(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("__browser-daemon", flag.ContinueOnError)
	flags.SetOutput(a.Err)
	config := devbrowser.Config{Out: a.Out, Err: a.Err}
	flags.StringVar(&config.State, "state", "", "")
	flags.StringVar(&config.Profile, "profile", "", "")
	flags.StringVar(&config.Marker, "marker", "", "")
	flags.StringVar(&config.SPKI, "spki", "", "")
	flags.BoolVar(&config.InBox, "box", false, "")
	if err := flags.Parse(args); err != nil || config.State == "" || config.Profile == "" || config.Marker == "" || config.SPKI == "" {
		return usage("invalid browser daemon arguments")
	}
	return devbrowser.RunDaemon(ctx, config)
}
