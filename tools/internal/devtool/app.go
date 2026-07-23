// Package devtool owns the repository's shared development workflows.
package devtool

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/andrewdryga/emisar/tools/internal/infraops"
)

const usageText = `usage: dev/run <command> [args]

  setup                    build the box, start dependencies, install deps, migrate
  up | down                start/stop this workspace's shared dependencies
  serve                    run Phoenix directly in the host or active Coop box
  seed                     explicitly apply the idempotent demo seed
  reset [--seed] [--yes]   destroy and recreate the dev database
  urls                     print this workspace's Portal, Postgres, and Keycloak URLs
  doctor                   verify tools, TLS, dependencies, and the OIDC issuer
  certs [--rotate|trust|untrust|status]
                           manage ignored Keycloak certificates and host trust
  browser <start|stop|status>
  shot <path> ...          capture through the persistent browser
  capture <docs|console>   run a full screenshot workflow against this workspace
  e2e <sso|signing|billing>
                           run a cross-component development scenario
  ops <portal|database|drill> ...
                           operate production infrastructure from a workstation
  check changed            compile, then check only changed Portal source files
  check portal             compile, format-check, and run Credo for all Portal files
  check staged             validate staged migrations and source formatting
  check infra-templates    render and validate production cloud-init
  check pack-environment [repo] [environment]
                           verify the registry deployment environment
  check agent-setup        validate shared agent manuals, skills, tasks, and hooks
  check tooling            lint and test the shared development tooling
  test portal <args...>    run focused, --stale, --failed, or listening Portal tests
  gate portal              run the canonical Portal gate
  loadtest <args...>       run the MCP concurrency harness
  pack check <name>        validate one pack without changing artifacts
  pack hashes [--write]    verify or refresh cross-language pack hash goldens
  pack sync <name> --fix   rebuild the authoritative catalog and focused tests
  pack test [pattern]      run generated pack cases against their real services
  smoke                    build and start the packaged root Compose topology
`

const (
	oidcSecret = "emisar-oidc-dev-secret-DO-NOT-USE-IN-PROD"
	scimToken  = "dev-scim-token"
)

type usageError struct{ message string }

func (e usageError) Error() string { return e.message }

// IsUsage reports whether err should produce command-line usage exit status 2.
func IsUsage(err error) bool {
	var target usageError
	return errors.As(err, &target)
}

// ExitCode preserves a failed child command's status when possible.
func ExitCode(err error) int {
	var target interface{ ExitCode() int }
	if errors.As(err, &target) && target.ExitCode() > 0 {
		return target.ExitCode()
	}
	return 1
}

type App struct {
	Root   string
	Portal string
	Certs  string
	In     io.Reader
	Out    io.Writer
	Err    io.Writer

	certsChanged bool
}

func New(root string, in io.Reader, out, errOut io.Writer) *App {
	return &App{
		Root:   root,
		Portal: filepath.Join(root, "portal"),
		Certs:  filepath.Join(root, "dev", "keycloak", "certs", "generated"),
		In:     in,
		Out:    out,
		Err:    errOut,
	}
}

func (a *App) usage() {
	fmt.Fprint(a.Out, usageText)
}

func usage(format string, args ...any) error {
	return usageError{message: fmt.Sprintf(format, args...)}
}

func exact(args []string, count int, text string) error {
	if len(args) != count {
		return usage("%s", text)
	}
	return nil
}

func (a *App) Run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		a.usage()
		return usage("a command is required")
	}

	command, rest := args[0], args[1:]
	if command == "__browser-daemon" {
		return a.browserDaemon(ctx, rest)
	}
	switch command {
	case "setup":
		if err := exact(rest, 0, "usage: dev/run setup"); err != nil {
			return err
		}
		return a.setup(ctx)
	case "up":
		if err := exact(rest, 0, "usage: dev/run up"); err != nil {
			return err
		}
		workspace, _, err := a.up(ctx)
		if err != nil {
			return err
		}
		if err := a.waitForDependencies(ctx, workspace); err != nil {
			return err
		}
		a.printURLs(workspace)
		return nil
	case "down":
		if err := exact(rest, 0, "usage: dev/run down"); err != nil {
			return err
		}
		if a.inBox() {
			return fmt.Errorf("run dev/run down on the host")
		}
		return a.run(ctx, a.Root, nil, "coop", "down")
	case "serve":
		if err := exact(rest, 0, "usage: dev/run serve"); err != nil {
			return err
		}
		return a.serve(ctx)
	case "seed":
		if err := exact(rest, 0, "usage: dev/run seed"); err != nil {
			return err
		}
		return a.seed(ctx)
	case "reset":
		return a.reset(ctx, rest)
	case "urls":
		if err := exact(rest, 0, "usage: dev/run urls"); err != nil {
			return err
		}
		workspace, err := a.loadWorkspace(ctx)
		if err != nil {
			return err
		}
		a.printURLs(workspace)
		return nil
	case "doctor":
		if err := exact(rest, 0, "usage: dev/run doctor"); err != nil {
			return err
		}
		return a.doctor(ctx)
	case "certs":
		return a.certsCommand(ctx, rest)
	case "browser":
		return a.browserCommand(ctx, rest)
	case "shot":
		return a.shot(ctx, rest)
	case "capture":
		return a.capture(ctx, rest)
	case "e2e":
		return a.e2e(ctx, rest)
	case "ops":
		return a.infraOps(ctx, rest)
	case "check", "test", "gate":
		return a.portalFeedback(ctx, command, rest)
	case "loadtest":
		return a.run(ctx, a.Root, nil, "go", append([]string{"run", "./tools/cmd/loadtest"}, rest...)...)
	case "pack":
		return a.pack(ctx, rest)
	case "smoke":
		if err := exact(rest, 0, "usage: dev/run smoke"); err != nil {
			return err
		}
		return a.smoke(ctx)
	case "help", "-h", "--help":
		a.usage()
		return nil
	default:
		a.usage()
		return usage("unknown command %q", command)
	}
}

func (a *App) infraOps(ctx context.Context, args []string) error {
	err := infraops.New(a.Root, a.In, a.Out, a.Err).Run(ctx, args)
	if infraops.IsUsage(err) {
		return usage("%s", err)
	}
	return err
}

func (a *App) cacheRoot() string {
	if root := os.Getenv("XDG_CACHE_HOME"); root != "" {
		return filepath.Join(root, "emisar")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "emisar")
}
