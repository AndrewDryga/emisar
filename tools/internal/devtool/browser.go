package devtool

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
)

func (a *App) browserManager(ctx context.Context, needs ...workspaceDependency) (*devbrowser.Manager, Workspace, error) {
	workspace, err := a.loadWorkspace(ctx, needs...)
	if err != nil {
		return nil, Workspace{}, err
	}
	port, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return nil, Workspace{}, err
	}
	spki := ""
	if workspace.KeycloakURL != "" {
		spki, err = a.tlsSPKI()
		if err != nil {
			return nil, Workspace{}, err
		}
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

func (a *App) startBrowser(ctx context.Context, needs ...workspaceDependency) (*devbrowser.Manager, Workspace, error) {
	manager, workspace, err := a.browserManager(ctx, needs...)
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
		_, _, err := a.startBrowser(ctx, needPortal)
		return err
	case "stop":
		manager, _, err := a.browserManager(ctx, needPortal)
		if err != nil {
			return err
		}
		if err := manager.Stop(ctx); err != nil {
			return err
		}
		fmt.Fprintln(a.Out, "browser stopped")
		return nil
	case "status":
		manager, _, err := a.browserManager(ctx, needPortal)
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

// shotCommand is one ./run shot invocation: one or more captures that share a browser session,
// and so one sign-in. Every bare argument starts a capture; the flags after it belong to it.
type shotCommand struct {
	shots  []devbrowser.ShotOptions
	taskID string
	group  string
}

const shotUsage = "usage: ./run shot <path> --label <name> [--task ID] [--group NAME] [--shot NAME|--select CSS|--heading TEXT|--class-contains a,b] [--climb SEL] [--click SEL]... [--fill '#ID=VALUE']... [--width N] [--settle MS] [<path> --label <name> [options]]..."

func parseShot(args []string) (shotCommand, error) {
	command := shotCommand{}
	// A bare argument opens a capture group; a flag without "=" takes the next argument as its
	// value, so a value that looks like a path (a selector, a fill) never opens one by accident.
	var groups [][]string
	for index := 0; index < len(args); index++ {
		if !strings.HasPrefix(args[index], "--") {
			groups = append(groups, []string{args[index]})
			continue
		}
		if len(groups) == 0 {
			return command, usage("%s", shotUsage)
		}
		last := len(groups) - 1
		groups[last] = append(groups[last], args[index])
		if !strings.Contains(args[index], "=") && index+1 < len(args) {
			index++
			groups[last] = append(groups[last], args[index])
		}
	}
	if len(groups) == 0 {
		return command, usage("%s", shotUsage)
	}
	labels := map[string]bool{}
	for _, group := range groups {
		options, taskID, groupName, err := parseShotGroup(group[0], group[1:])
		if err != nil {
			return command, err
		}
		// The task and group name the one output directory of the whole batch.
		if taskID != "" && command.taskID != "" && taskID != command.taskID {
			return command, usage("shot: one --task per invocation (got %q and %q)", command.taskID, taskID)
		}
		if groupName != "" && command.group != "" && groupName != command.group {
			return command, usage("shot: one --group per invocation (got %q and %q)", command.group, groupName)
		}
		if labels[options.Label] {
			return command, usage("shot: --label %q is used twice; each capture in a batch needs its own label", options.Label)
		}
		labels[options.Label] = true
		command.taskID, command.group = cmp.Or(command.taskID, taskID), cmp.Or(command.group, groupName)
		command.shots = append(command.shots, options)
	}
	return command, nil
}

func parseShotGroup(path string, args []string) (devbrowser.ShotOptions, string, string, error) {
	options := devbrowser.ShotOptions{Path: path, Email: os.Getenv("EMAIL"), Width: 1440}
	flags := flag.NewFlagSet("shot", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	taskID, group := "", ""
	shot, selector, heading, classContains, climb := "", "", "", "", ""
	settle := 0
	flags.StringVar(&options.Label, "label", "", "")
	flags.StringVar(&taskID, "task", "", "")
	flags.StringVar(&group, "group", "", "")
	flags.StringVar(&shot, "shot", "", "")
	flags.StringVar(&selector, "select", "", "")
	flags.StringVar(&heading, "heading", "", "")
	flags.StringVar(&classContains, "class-contains", "", "")
	flags.StringVar(&climb, "climb", "", "")
	flags.Func("click", "", func(value string) error {
		options.Clicks = append(options.Clicks, value)
		return nil
	})
	flags.Func("fill", "", func(value string) error {
		selector, text, ok := strings.Cut(value, "=")
		if !ok || !regexp.MustCompile(`^#[A-Za-z_][A-Za-z0-9_-]*$`).MatchString(selector) {
			return fmt.Errorf("fill requires #ID=VALUE (an ID selector, not arbitrary CSS)")
		}
		options.Fills = append(options.Fills, devbrowser.FieldFill{Selector: selector, Value: text})
		return nil
	})
	flags.Int64Var(&options.Width, "width", 1440, "")
	flags.IntVar(&settle, "settle", 0, "")
	if err := flags.Parse(args); err != nil || options.Label == "" || flags.NArg() != 0 {
		return options, "", "", usage("%s", shotUsage)
	}
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
	return options, taskID, group, nil
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
	fmt.Fprintf(a.Out, "screenshot task %s -> %s\n", task.ID, output)
	manager, workspace, err := a.startBrowser(ctx, needPortal)
	if err != nil {
		return err
	}
	session, err := manager.Session(ctx, workspace.PortalURL, false)
	if err != nil {
		return err
	}
	defer session.Close()
	// One session for the whole batch: the first capture that lands on /sign_in signs in, and
	// every later one rides that cookie, so a related set costs one sign-in email, not one each.
	// Each capture still navigates to its own path afresh, so clicks and fills never bleed over.
	for _, options := range command.shots {
		options.Out = output
		paths, err := session.Shot(options)
		if err != nil {
			if len(command.shots) > 1 {
				return fmt.Errorf("%s: %w", options.Label, err)
			}
			return err
		}
		for _, path := range paths {
			fmt.Fprintln(a.Out, path)
		}
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
	if err := flags.Parse(args); err != nil || config.State == "" || config.Profile == "" || config.Marker == "" {
		return usage("invalid browser daemon arguments")
	}
	return devbrowser.RunDaemon(ctx, config)
}
