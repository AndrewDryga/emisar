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

const usageText = `usage: ./run <command> [args]

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
  shot <path> ...          capture proof into the active task's screenshots
  capture <docs|console>   capture task-owned console proof or committed docs assets
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
  check packs              validate every pack and cross-language hash golden
  check agent-setup        validate shared agent manuals, skills, tasks, and hooks
  test <target> [args...]  run focused Portal, Go, pack, or installer tests
  gate <target>            run a canonical project gate; use "gate all" for every gate
  loadtest <args...>       run the MCP concurrency harness
  pack check <name>        validate one pack without changing artifacts
  pack hashes [--write]    verify or refresh cross-language pack hash goldens
  pack sync <name> --fix   rebuild the authoritative catalog and focused tests
  smoke                    build and start the packaged root Compose topology

Run "./run help <check|test|gate|pack|ops>" for focused help.
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
		if err := exact(rest, 0, "usage: ./run down"); err != nil {
			return err
		}
		if a.inBox() {
			return fmt.Errorf("run ./run down on the host")
		}
		return a.run(ctx, a.Root, nil, "coop", "down")
	case "serve":
		if err := exact(rest, 0, "usage: ./run serve"); err != nil {
			return err
		}
		return a.serve(ctx)
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
	case "loadtest":
		return a.run(ctx, a.Root, nil, "go", append([]string{"run", "./tools/cmd/loadtest"}, rest...)...)
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
