// Package infraops owns workstation and CI operations for the production
// Terraform project. Deployed host scripts remain under infra/runtime.
package infraops

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const usageText = `usage: ./run ops <command> [args]

  portal ...                         operate Portal VMs through IAP
  database ...                       open the private production database tunnel
  drill pitr [--apply]               run the PITR and IAM recovery drill
  drill cleanup [--apply [ID]]       list or clean recovery drill resources
  validate-templates                 render and validate production cloud-init
  verify-pack-environment [repo] [environment]
                                     verify the registry deployment environment
`

type usageError struct{ message string }

func (e usageError) Error() string { return e.message }

func usage(format string, args ...any) error {
	return usageError{message: fmt.Sprintf(format, args...)}
}

// IsUsage reports whether an error represents invalid command arguments.
func IsUsage(err error) bool {
	var target usageError
	return errors.As(err, &target)
}

// App executes infrastructure operations through explicit external CLIs.
type App struct {
	Root     string
	Infra    string
	In       io.Reader
	Out      io.Writer
	Err      io.Writer
	LookPath func(string) (string, error)
}

// New creates an infrastructure operations application.
func New(root string, in io.Reader, out, errOut io.Writer) *App {
	return &App{
		Root: root, Infra: filepath.Join(root, "infra"),
		In: in, Out: out, Err: errOut, LookPath: exec.LookPath,
	}
}

// Run dispatches one infrastructure operation.
func (a *App) Run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		fmt.Fprint(a.Out, usageText)
		return usage("a command is required")
	}
	switch args[0] {
	case "portal":
		return a.portal(ctx, args[1:])
	case "database":
		return a.database(ctx, args[1:])
	case "drill":
		if len(args) < 2 {
			return usage("usage: ./run ops drill <pitr|cleanup> [options]")
		}
		switch args[1] {
		case "pitr":
			return a.pitrDrill(ctx, args[2:])
		case "cleanup":
			return a.cleanupDrills(ctx, args[2:])
		default:
			return usage("unknown drill %q", args[1])
		}
	case "validate-templates":
		if len(args) != 1 {
			return usage("usage: ./run ops validate-templates")
		}
		return a.validateTemplates(ctx)
	case "verify-pack-environment":
		if len(args) > 3 {
			return usage("usage: ./run ops verify-pack-environment [repo] [environment]")
		}
		repo := "AndrewDryga/emisar"
		environment := "pack-registry-production"
		if len(args) > 1 {
			repo = args[1]
		}
		if len(args) > 2 {
			environment = args[2]
		}
		return a.verifyPackEnvironment(ctx, repo, environment)
	case "help", "-h", "--help":
		fmt.Fprint(a.Out, usageText)
		return nil
	default:
		fmt.Fprint(a.Out, usageText)
		return usage("unknown command %q", args[0])
	}
}

func mergedEnv(overrides map[string]string) []string {
	values := make(map[string]string)
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			values[key] = value
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}

func (a *App) command(ctx context.Context, dir string, env map[string]string, name string, args ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = mergedEnv(env)
	command.Stdin = a.In
	command.Stdout = a.Out
	command.Stderr = a.Err
	return command
}

func (a *App) require(names ...string) error {
	for _, name := range names {
		if _, err := a.LookPath(name); err != nil {
			return fmt.Errorf("%s is required but not installed", name)
		}
	}
	return nil
}

func (a *App) run(ctx context.Context, dir string, env map[string]string, name string, args ...string) error {
	if err := a.require(name); err != nil {
		return err
	}
	if err := a.command(ctx, dir, env, name, args...).Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

func (a *App) output(ctx context.Context, dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	if err := a.require(name); err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = mergedEnv(env)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		if stderr.Len() != 0 {
			return nil, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
		}
		return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return stdout.Bytes(), nil
}

func (a *App) project(ctx context.Context, configured string) (string, error) {
	if configured != "" {
		return configured, nil
	}
	output, err := a.output(ctx, a.Root, nil, "gcloud", "config", "get-value", "project")
	if err != nil {
		return "", err
	}
	project := strings.TrimSpace(string(output))
	if project == "" || project == "(unset)" {
		return "", fmt.Errorf("no GCP project configured; pass --project or set EMISAR_GCP_PROJECT")
	}
	return project, nil
}

func lines(data []byte) []string {
	var result []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line != "" {
			result = append(result, line)
		}
	}
	return result
}
