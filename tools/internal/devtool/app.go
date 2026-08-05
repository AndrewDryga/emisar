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

const usageText = `Emisar development

Usage:
  ./run <command> [arguments]

First run:
  ./run bootstrap             Print box-first and native prerequisite commands
  ./run setup                 Prepare tools, services, dependencies, and the database
  ./run serve                 Start Phoenix with live reload

Fast feedback:
  ./run test portal --stale   Re-run tests affected by recent edits
  ./run check changed         Check changed Portal source files
  ./run gate portal           Run the complete Portal gate before committing

Local development:
  setup                       Prepare the complete development environment
  up                          Start PostgreSQL and Keycloak
  down [--all]                Stop PostgreSQL and Keycloak, or every started stack
  serve [--iex]               Start Phoenix, optionally with an interactive IEx shell
  status                      Show workspace listeners and sidecar state without changing it
  logs [--follow] [service]   Show scoped db/keycloak logs (host only)
  psql [psql-args...]         Open this workspace's development database
  seed                        Load or refresh the idempotent demo data
  reset [--seed] [--yes]      Recreate the development database
  urls                        Print Portal, PostgreSQL, and Keycloak URLs
  doctor                      Diagnose tools, services, TLS, and OIDC
  certs <action>              Manage certificates and trust: status, trust, untrust, rotate

Test and verify:
  test <target> [args...]     Run focused Portal, Go, pack, or installer tests
  check <target>              Run a quick or specialized repository check
  gate <target>               Run all required checks for a project

Browser and UI:
  browser <action>            Manage the persistent browser: start, stop, status
  shot <path> [options]       Save UI proof under the active task
  capture <docs|console>      Regenerate docs assets or audit the console

Cross-component scenarios:
  e2e <sso|signing|billing>   Exercise a complete development scenario
  smoke                       Run the packaged, release-like Compose stack

Action packs:
  pack check <name>           Validate one pack
  pack hashes [--write]       Verify or refresh pack hash goldens
  pack sync <name> --fix      Rebuild the catalog and focused tests

Production operations:
  ops <portal|database|drill>  Operate infrastructure from a workstation

More help:
  help [topic]                Show help for check, test, gate, pack, or ops
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

	certsChanged        bool
	serviceForwardStops []func()
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
	defer a.stopServiceForwards()

	if len(args) == 0 {
		a.usage()
		return nil
	}

	command, rest := args[0], args[1:]
	if command == "__browser-daemon" {
		return a.browserDaemon(ctx, rest)
	}
	switch command {
	case "setup":
		if err := exact(rest, 0, "usage: ./run setup"); err != nil {
			return err
		}
		return a.setup(ctx)
	case "up":
		if err := exact(rest, 0, "usage: ./run up"); err != nil {
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
		return a.down(ctx, rest)
	case "serve":
		iex := false
		if len(rest) == 1 && rest[0] == "--iex" {
			iex = true
		} else if len(rest) != 0 {
			return usage("usage: ./run serve [--iex]")
		}
		return a.serve(ctx, iex)
	case "status":
		if err := exact(rest, 0, "usage: ./run status"); err != nil {
			return err
		}
		return a.status(ctx)
	case "logs":
		return a.logs(ctx, rest)
	case "psql":
		return a.psql(ctx, rest)
	case "seed":
		if err := exact(rest, 0, "usage: ./run seed"); err != nil {
			return err
		}
		return a.seed(ctx)
	case "reset":
		return a.reset(ctx, rest)
	case "urls":
		if err := exact(rest, 0, "usage: ./run urls"); err != nil {
			return err
		}
		workspace, err := a.loadWorkspace(ctx)
		if err != nil {
			return err
		}
		a.printURLs(workspace)
		return nil
	case "doctor":
		if err := exact(rest, 0, "usage: ./run doctor"); err != nil {
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
	case "check":
		return a.check(ctx, rest)
	case "test":
		return a.test(ctx, rest)
	case "gate":
		return a.gate(ctx, rest)
	case "pack":
		return a.pack(ctx, rest)
	case "smoke":
		if err := exact(rest, 0, "usage: ./run smoke"); err != nil {
			return err
		}
		return a.smoke(ctx)
	case "help":
		return a.help(rest)
	case "-h", "--help":
		return a.help(nil)
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
