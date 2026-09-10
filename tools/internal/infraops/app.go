// Package infraops owns workstation and CI operations for the production
// Terraform project. Deployed host scripts remain under infra/runtime.
package infraops

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

const usageText = `usage: ./run ops <command> [args]

  portal ...                         operate Portal VMs through IAP
  database ...                       open the private production database tunnel
  drill pitr [--apply]               run the PITR and IAM recovery drill
  drill cleanup [--apply [ID]]       list or clean recovery drill resources
  validate-templates                 render and validate production cloud-init
  verify-release-pins [--resolve-comments]
                                     verify trusted release workflow commit pins and WIF literals;
                                     --resolve-comments also resolves every action pin's version
                                     comment against upstream tags (network, outside the gate)
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
	toolutil.Runner
	Root      string
	Infra     string
	GitHubAPI string
}

// New creates an infrastructure operations application.
func New(root string, in io.Reader, out, errOut io.Writer) *App {
	return &App{
		Runner: toolutil.Runner{In: in, Out: out, Err: errOut, LookPath: exec.LookPath},
		Root:   root, Infra: filepath.Join(root, "infra"),
		GitHubAPI: githubAPI,
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
	case "verify-release-pins":
		resolveComments := false
		switch {
		case len(args) == 1:
		case len(args) == 2 && args[1] == "--resolve-comments":
			resolveComments = true
		default:
			return usage("usage: ./run ops verify-release-pins [--resolve-comments]")
		}
		if err := a.checkTrustedReleasePins(ctx); err != nil {
			return err
		}
		if err := a.checkWorkloadIdentityLiterals(); err != nil {
			return err
		}
		if !resolveComments {
			return nil
		}
		return a.checkReleasePinComments(ctx)
	case "help", "-h", "--help":
		fmt.Fprint(a.Out, usageText)
		return nil
	default:
		fmt.Fprint(a.Out, usageText)
		return usage("unknown command %q", args[0])
	}
}

// The lowercase names every command in this package calls; the behaviour
// lives in toolutil.Runner, shared with devtool.
func (a *App) command(ctx context.Context, dir string, env map[string]string, name string, args ...string) *exec.Cmd {
	return a.Runner.Command(ctx, dir, env, name, args...)
}

func (a *App) require(names ...string) error { return a.Runner.Require(names...) }

func (a *App) run(ctx context.Context, dir string, env map[string]string, name string, args ...string) error {
	return a.Runner.Run(ctx, dir, env, name, args...)
}

func (a *App) output(ctx context.Context, dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	return a.Runner.Output(ctx, dir, env, name, args...)
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
