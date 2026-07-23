package infraops

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const portalUsage = `usage: dev/run ops portal [options] <command> [args...]

Options:
  --project PROJECT        GCP project (defaults to EMISAR_GCP_PROJECT or gcloud config)
  --host NAME              select a Portal VM by name; repeatable
  --list-hosts             print eligible Portal VM names
  --reuse-last-selection   reuse this terminal session's last selection

Commands:
  ssh
  remsh
  logs [-f|--follow]
  journal
  status
  version
  cmd <shell-command>
`

var hostName = regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?$`)

type portalOptions struct {
	project       string
	requested     []string
	listHosts     bool
	reuse         bool
	command       string
	commandArgs   []string
	follow        bool
	selectionFile string
}

type instance struct {
	name string
	zone string
	raw  string
}

func parsePortalOptions(args []string) (portalOptions, error) {
	options := portalOptions{project: os.Getenv("EMISAR_GCP_PROJECT")}
	for len(args) > 0 {
		switch args[0] {
		case "--project":
			if len(args) < 2 {
				return options, usage("--project requires a value")
			}
			options.project, args = args[1], args[2:]
		case "--host":
			if len(args) < 2 {
				return options, usage("--host requires a value")
			}
			if !hostName.MatchString(args[1]) {
				return options, usage("invalid host name: %s", args[1])
			}
			for _, existing := range options.requested {
				if existing == args[1] {
					return options, usage("host selected more than once: %s", args[1])
				}
			}
			options.requested = append(options.requested, args[1])
			args = args[2:]
		case "--list-hosts":
			options.listHosts, args = true, args[1:]
		case "--reuse-last-selection":
			options.reuse, args = true, args[1:]
		case "-h", "--help":
			return options, usage(portalUsage)
		case "--":
			args = args[1:]
			goto command
		default:
			if strings.HasPrefix(args[0], "-") {
				return options, usage("unknown option: %s", args[0])
			}
			goto command
		}
	}

command:
	if options.listHosts {
		if len(args) != 0 || options.reuse || len(options.requested) != 0 {
			return options, usage("--list-hosts cannot be combined with a command, --host, or --reuse-last-selection")
		}
		return options, nil
	}
	if options.reuse && len(options.requested) != 0 {
		return options, usage("--host cannot be combined with --reuse-last-selection")
	}
	if len(args) == 0 {
		return options, usage(portalUsage)
	}
	options.command, options.commandArgs = args[0], args[1:]
	switch options.command {
	case "ssh", "remsh", "journal", "status", "version":
		if len(options.commandArgs) != 0 {
			return options, usage("%s does not accept arguments", options.command)
		}
	case "logs":
		if len(options.commandArgs) == 1 &&
			(options.commandArgs[0] == "-f" || options.commandArgs[0] == "--follow") {
			options.follow = true
		} else if len(options.commandArgs) != 0 {
			return options, usage("logs accepts only -f or --follow")
		}
	case "cmd":
		if len(options.commandArgs) == 0 {
			return options, usage("cmd requires a shell command")
		}
	default:
		return options, usage("unknown Portal command: %s", options.command)
	}
	return options, nil
}

func parseInstances(data []byte) ([]instance, error) {
	var result []instance
	for _, line := range lines(data) {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 || fields[0] == "" || fields[1] == "" {
			return nil, fmt.Errorf("invalid Portal inventory row %q", line)
		}
		result = append(result, instance{name: fields[0], zone: fields[1], raw: line})
	}
	return result, nil
}

func (a *App) portalInventory(ctx context.Context, project string) ([]byte, error) {
	return a.output(ctx, a.Root, map[string]string{
		"CLOUDSDK_COMPUTE_ZONE": "", "CLOUDSDK_COMPUTE_REGION": "",
	}, "gcloud", "compute", "instances", "list",
		"--project="+project, "--filter=labels.cluster_name=emisar",
		"--sort-by=creationTimestamp",
		"--format=value(name,zone.basename(),status,creationTimestamp,machineType.basename())")
}

func selectionKey(project string) string {
	session := os.Getenv("EMISAR_PORTAL_SESSION_KEY")
	for _, variable := range []string{"TMUX_PANE", "SHELL_SESSION_ID", "TERM_SESSION_ID", "ITERM_SESSION_ID"} {
		if session == "" {
			session = os.Getenv(variable)
		}
	}
	if session == "" {
		session = topShellPID()
	}
	if session == "" {
		session = fmt.Sprint(os.Getppid())
	}
	clean := func(value string) string {
		return regexp.MustCompile(`[^A-Za-z0-9._-]`).ReplaceAllString(value, "_")
	}
	cache := os.Getenv("XDG_CACHE_HOME")
	if cache == "" {
		home, _ := os.UserHomeDir()
		cache = filepath.Join(home, ".cache")
	}
	return filepath.Join(cache, "emisar", "portal",
		clean(project)+"_session_"+clean(session)+".selection")
}

func topShellPID() string {
	shells := map[string]bool{
		"zsh": true, "bash": true, "fish": true, "sh": true,
		"dash": true, "ksh": true,
	}
	pid := os.Getpid()
	result := ""
	for pid > 1 {
		command, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			break
		}
		name := strings.TrimPrefix(filepath.Base(strings.TrimSpace(string(command))), "-")
		if shells[name] {
			result = strconv.Itoa(pid)
		}
		parent, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			break
		}
		next, err := strconv.Atoi(strings.TrimSpace(string(parent)))
		if err != nil || next <= 1 || next == pid {
			break
		}
		pid = next
	}
	return result
}

func (a *App) selectInstances(ctx context.Context, options portalOptions, inventory []byte) ([]instance, error) {
	all, err := parseInstances(inventory)
	if err != nil {
		return nil, err
	}
	if len(options.requested) != 0 {
		var selected []instance
		for _, requested := range options.requested {
			found := false
			for _, candidate := range all {
				if candidate.name == requested {
					selected = append(selected, candidate)
					found = true
				}
			}
			if !found {
				return nil, fmt.Errorf("Portal host not found: %s", requested)
			}
		}
		return selected, nil
	}
	options.selectionFile = selectionKey(options.project)
	if override := os.Getenv("EMISAR_PORTAL_LAST_SELECTION_FILE"); override != "" {
		options.selectionFile = override
	}
	if options.reuse {
		raw := os.Getenv("EMISAR_PORTAL_LAST_SELECTION")
		if raw == "" {
			data, readErr := os.ReadFile(options.selectionFile)
			if readErr != nil {
				return nil, fmt.Errorf("no cached Portal selection found; run without --reuse-last-selection first")
			}
			raw = string(data)
		}
		return parseInstances([]byte(raw))
	}
	if err := a.require("fzf"); err != nil {
		return nil, err
	}
	command := a.command(ctx, a.Root, nil, "fzf",
		"--multi", "--delimiter=\t", "--with-nth=1,2,3,4,5",
		"--header=NAME\tZONE\tSTATUS\tCREATED\tMACHINE TYPE")
	command.Stdin = strings.NewReader(string(inventory))
	command.Stdout = nil
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("selecting Portal instances: %w", err)
	}
	selected, err := parseInstances(output)
	if err != nil {
		return nil, err
	}
	if len(selected) == 0 {
		return nil, fmt.Errorf("no Portal instances selected")
	}
	if err := os.MkdirAll(filepath.Dir(options.selectionFile), 0o700); err != nil {
		return nil, err
	}
	var raw strings.Builder
	for _, item := range selected {
		raw.WriteString(item.raw)
		raw.WriteByte('\n')
	}
	if err := os.WriteFile(options.selectionFile, []byte(raw.String()), 0o600); err != nil {
		return nil, err
	}
	return selected, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func remotePortalCommand(options portalOptions) string {
	switch options.command {
	case "logs":
		if options.follow {
			return "sudo docker logs --tail=200 --follow emisar"
		}
		return "sudo docker logs --tail=200 emisar"
	case "journal":
		return "sudo journalctl --unit=emisar.service --lines=200 --no-pager"
	case "status":
		return "sudo systemctl status emisar.service --no-pager"
	case "version":
		return "sudo docker exec emisar cut -d ' ' -f2 /app/releases/start_erl.data"
	case "cmd":
		var command string
		if len(options.commandArgs) == 1 {
			command = options.commandArgs[0]
		} else {
			parts := make([]string, len(options.commandArgs))
			for index, argument := range options.commandArgs {
				parts[index] = shellQuote(argument)
			}
			command = strings.Join(parts, " ")
		}
		return "bash -lc " + shellQuote(command)
	default:
		return ""
	}
}

func (a *App) gssh(ctx context.Context, project string, instance instance, args ...string) error {
	base := []string{
		"compute", "ssh", instance.name, "--project=" + project,
		"--zone=" + instance.zone, "--tunnel-through-iap",
	}
	base = append(base, args...)
	return a.run(ctx, a.Root, map[string]string{
		"CLOUDSDK_COMPUTE_ZONE": "", "CLOUDSDK_COMPUTE_REGION": "",
	}, "gcloud", base...)
}

func (a *App) portal(ctx context.Context, args []string) error {
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprint(a.Out, portalUsage)
		return nil
	}
	options, err := parsePortalOptions(args)
	if err != nil {
		return err
	}
	if err := a.require("gcloud"); err != nil {
		return err
	}
	options.project, err = a.project(ctx, options.project)
	if err != nil {
		return err
	}
	inventory, err := a.portalInventory(ctx, options.project)
	if err != nil {
		return err
	}
	if options.listHosts {
		instances, err := parseInstances(inventory)
		if err != nil {
			return err
		}
		for _, item := range instances {
			fmt.Fprintln(a.Out, item.name)
		}
		return nil
	}
	selected, err := a.selectInstances(ctx, options, inventory)
	if err != nil {
		return err
	}
	if len(selected) > 1 && (options.command == "ssh" || options.command == "remsh") {
		return fmt.Errorf("%s supports exactly one selected VM", options.command)
	}
	if options.command == "ssh" {
		fmt.Fprintf(a.Out, "Starting SSH session on %s (%s)...\n", selected[0].name, selected[0].zone)
		return a.gssh(ctx, options.project, selected[0])
	}
	if options.command == "remsh" {
		fmt.Fprintf(a.Out, "Attaching to the Emisar release on %s (%s)...\n", selected[0].name, selected[0].zone)
		return a.gssh(ctx, options.project, selected[0],
			"--command=sudo docker exec -it emisar /app/bin/emisar remote", "--", "-t")
	}
	remote := remotePortalCommand(options)
	if len(selected) == 1 {
		fmt.Fprintf(a.Out, "Running %s on %s (%s)...\n", options.command, selected[0].name, selected[0].zone)
		return a.gssh(ctx, options.project, selected[0], "--command="+remote)
	}
	names := make([]string, len(selected))
	for index, item := range selected {
		names[index] = item.name
	}
	fmt.Fprintf(a.Out, "Running %s over SSH on %s at %s...\n",
		options.command, strings.Join(names, ", "), time.Now().Format(time.RFC3339))

	var failed atomic.Bool
	var wait sync.WaitGroup
	for _, item := range selected {
		item := item
		wait.Add(1)
		go func() {
			defer wait.Done()
			command := a.command(ctx, a.Root, map[string]string{
				"CLOUDSDK_COMPUTE_ZONE": "", "CLOUDSDK_COMPUTE_REGION": "",
			}, "gcloud", "compute", "ssh", item.name, "--project="+options.project,
				"--zone="+item.zone, "--tunnel-through-iap", "--command="+remote)
			command.Stdout = nil
			stdout, err := command.StdoutPipe()
			if err != nil {
				fmt.Fprintln(a.Err, err)
				failed.Store(true)
				return
			}
			command.Stderr = command.Stdout
			if err := command.Start(); err != nil {
				fmt.Fprintln(a.Err, err)
				failed.Store(true)
				return
			}
			scanner := bufio.NewScanner(stdout)
			for scanner.Scan() {
				fmt.Fprintf(a.Out, "[%s] %s\n", item.name, scanner.Text())
			}
			if scanner.Err() != nil || command.Wait() != nil {
				failed.Store(true)
			}
		}()
	}
	wait.Wait()
	if failed.Load() {
		return fmt.Errorf("one or more Portal commands failed")
	}
	return nil
}
