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
		return usage("usage: ./run browser <start|stop|status>")
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
		return usage("usage: ./run browser <start|stop|status>")
	}
}

type shotCommand struct {
	options devbrowser.ShotOptions
	taskID  string
	group   string
}

func parseShot(args []string) (shotCommand, error) {
	command := shotCommand{options: devbrowser.ShotOptions{Email: os.Getenv("EMAIL"), Width: 1440}}
	flags := flag.NewFlagSet("shot", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	shot, selector, heading, classContains, climb := "", "", "", "", ""
	settle := 0
	flags.StringVar(&command.options.Label, "label", "", "")
	flags.StringVar(&command.taskID, "task", "", "")
	flags.StringVar(&command.group, "group", "", "")
	flags.StringVar(&shot, "shot", "", "")
	flags.StringVar(&selector, "select", "", "")
	flags.StringVar(&heading, "heading", "", "")
	flags.StringVar(&classContains, "class-contains", "", "")
	flags.StringVar(&climb, "climb", "", "")
	flags.StringVar(&command.options.Click, "click", "", "")
	flags.Int64Var(&command.options.Width, "width", 1440, "")
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
	if err := flags.Parse(flagArgs); err != nil || path == "" || command.options.Label == "" || flags.NArg() != 0 {
		return command, usage("usage: ./run shot <path> --label <name> [--task ID] [--group NAME] [--shot NAME|--select CSS|--heading TEXT|--class-contains a,b] [--climb SEL] [--click SEL] [--width N] [--settle MS]")
	}
	command.options.Path = path
	command.options.Settle = time.Duration(settle) * time.Millisecond
	if shot != "" {
		selector = `[data-shot='` + strings.ReplaceAll(shot, `'`, `\'`) + `']`
	}
	if selector != "" || heading != "" || classContains != "" {
		command.options.Anchor = &devbrowser.Anchor{Selector: selector, Heading: heading, Climb: climb}
		if classContains != "" {
			command.options.Anchor.ClassContains = strings.Split(classContains, ",")
		}
	}
	return command, nil
}

func (a *App) shot(ctx context.Context, args []string) error {
	command, err := parseShot(args)
	if err != nil {
		return err
	}
	task, output, err := a.screenshotOutput(command.taskID, command.group)
	if err != nil {
		return err
	}
	command.options.Out = output
	fmt.Fprintf(a.Out, "screenshot task %s -> %s\n", task.ID, output)
	manager, workspace, err := a.startBrowser(ctx)
	if err != nil {
		return err
	}
	session, err := manager.Session(ctx, workspace.PortalURL, false)
	if err != nil {
		return err
	}
	defer session.Close()
	paths, err := session.Shot(command.options)
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
