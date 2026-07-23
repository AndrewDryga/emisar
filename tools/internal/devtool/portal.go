package devtool

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	ansiPattern      = regexp.MustCompile(`\x1b\[[0-9;]*[[:alpha:]]`)
	pollutionPattern = regexp.MustCompile(`(?mi)(^|[[:space:]])warning:|\[(error|warning)\]|(^|[[:space:]])error:|Postgrex\.Protocol .*disconnected|DBConnection\.ConnectionError`)
)

func (a *App) runCaptured(ctx context.Context, label, dir string, env map[string]string, name string, args ...string) error {
	fmt.Fprintf(a.Out, "==> %s\n", label)
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = mergedEnv(env)
	command.Stdin = a.In
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	clean := ansiPattern.ReplaceAllString(output.String(), "")
	if err != nil {
		copyOutput(a.Out, output.Bytes())
		return fmt.Errorf("%s failed: %w", label, err)
	}
	if matches := pollutionPattern.FindAllString(clean, -1); len(matches) > 0 {
		for lineNumber, line := range strings.Split(clean, "\n") {
			if pollutionPattern.MatchString(line) {
				fmt.Fprintf(a.Err, "%d:%s\n", lineNumber+1, line)
			}
		}
		copyOutput(a.Out, output.Bytes())
		return fmt.Errorf("%s polluted test output; fix the warning/error/log source", label)
	}
	copyOutput(a.Out, output.Bytes())
	return nil
}

func (a *App) portalTestOutput(ctx context.Context, env map[string]string) error {
	testEnv := make(map[string]string, len(env)+1)
	for key, value := range env {
		testEnv[key] = value
	}
	testEnv["MIX_ENV"] = "test"
	fmt.Fprintln(a.Out, "==> deps warm-up (unscanned: third-party compile warnings are not ours)")
	if err := a.run(ctx, a.Portal, testEnv, "mix", "deps.compile"); err != nil {
		return fmt.Errorf("deps compile failed: %w", err)
	}
	checks := []struct {
		label string
		dir   string
		args  []string
	}{
		{"database setup and migrations", filepath.Join(a.Portal, "apps", "emisar"), []string{"ecto.create", "--quiet"}},
		{"database migrations", filepath.Join(a.Portal, "apps", "emisar"), []string{"ecto.migrate", "--quiet"}},
		{"emisar app tests", filepath.Join(a.Portal, "apps", "emisar"), []string{"test"}},
		{"emisar_web app tests", filepath.Join(a.Portal, "apps", "emisar_web"), []string{"test"}},
	}
	for _, check := range checks {
		if err := a.runCaptured(ctx, check.label, check.dir, testEnv, "mix", check.args...); err != nil {
			return err
		}
	}
	fmt.Fprintln(a.Out, "ok: portal test output is clean")
	return nil
}

func nulFields(data []byte) []string {
	values := make([]string, 0)
	for _, field := range bytes.Split(data, []byte{0}) {
		if len(field) > 0 {
			values = append(values, string(field))
		}
	}
	return values
}

func (a *App) changedPortalFiles(ctx context.Context) ([]string, error) {
	changed, err := a.output(ctx, a.Root, nil, "git", "diff", "--name-only", "-z", "--diff-filter=ACMR", "HEAD", "--", "portal")
	if err != nil {
		return nil, err
	}
	untracked, err := a.output(ctx, a.Root, nil, "git", "ls-files", "-z", "--others", "--exclude-standard", "--", "portal")
	if err != nil {
		return nil, err
	}
	set := make(map[string]struct{})
	for _, path := range append(nulFields(changed), nulFields(untracked)...) {
		set[path] = struct{}{}
	}
	paths := make([]string, 0, len(set))
	for path := range set {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths, nil
}

func (a *App) changedPortalCheck(ctx context.Context) error {
	paths, err := a.changedPortalFiles(ctx)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		fmt.Fprintln(a.Out, "no changed Portal files")
		return nil
	}
	if err := a.run(ctx, a.Portal, nil, "mix", "compile", "--warnings-as-errors"); err != nil {
		return err
	}
	formatFiles, credoFiles := []string{}, []string{}
	for _, path := range paths {
		absolute := filepath.Join(a.Root, filepath.FromSlash(path))
		if info, statErr := os.Stat(absolute); statErr != nil || info.IsDir() {
			continue
		}
		relative := strings.TrimPrefix(path, "portal/")
		switch filepath.Ext(relative) {
		case ".ex", ".exs":
			formatFiles = append(formatFiles, relative)
			credoFiles = append(credoFiles, relative)
		case ".heex":
			formatFiles = append(formatFiles, relative)
		}
	}
	if len(formatFiles) > 0 {
		fmt.Fprintf(a.Out, "Checking format: %s\n", strings.Join(formatFiles, " "))
		if err := a.run(ctx, a.Portal, nil, "mix", append([]string{"format", "--check-formatted"}, formatFiles...)...); err != nil {
			return err
		}
	}
	if len(credoFiles) > 0 {
		fmt.Fprintf(a.Out, "Checking Credo: %s\n", strings.Join(credoFiles, " "))
		if err := a.run(ctx, a.Portal, nil, "mix", append([]string{"credo"}, credoFiles...)...); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) portalTests(ctx context.Context, env map[string]string, args []string) error {
	app := ""
	for _, argument := range args {
		candidate := ""
		switch {
		case strings.HasPrefix(argument, "apps/emisar/"):
			candidate = "emisar"
		case strings.HasPrefix(argument, "apps/emisar_web/"):
			candidate = "emisar_web"
		}
		if candidate != "" && app != "" && candidate != app {
			return usage("focused test paths must belong to one Portal app")
		}
		if candidate != "" {
			app = candidate
		}
	}
	testEnv := make(map[string]string, len(env)+1)
	for key, value := range env {
		testEnv[key] = value
	}
	testEnv["MIX_ENV"] = "test"
	if app == "" {
		return a.run(ctx, a.Portal, testEnv, "mix", append([]string{"test"}, args...)...)
	}
	appArgs := make([]string, 0, len(args)+1)
	appArgs = append(appArgs, "test")
	for _, argument := range args {
		if strings.HasPrefix(argument, "apps/"+app+"/") {
			appArgs = append(appArgs, strings.TrimPrefix(argument, "apps/"+app+"/"))
		} else if strings.HasPrefix(argument, "apps/emisar/") || strings.HasPrefix(argument, "apps/emisar_web/") {
			return usage("focused test paths must belong to one Portal app")
		} else {
			appArgs = append(appArgs, argument)
		}
	}
	return a.run(ctx, filepath.Join(a.Portal, "apps", app), testEnv, "mix", appArgs...)
}

func (a *App) agentSetupCheck(ctx context.Context, requireCoop bool) error {
	args := []string{"run", "./tools/cmd/agentcheck"}
	if requireCoop {
		args = append(args, "--require-coop")
	}
	return a.run(ctx, a.Root, nil, "go", args...)
}

func (a *App) toolingCheck(ctx context.Context) error {
	if err := a.run(ctx, filepath.Join(a.Root, "tools"), nil, "go", "mod", "verify"); err != nil {
		return err
	}
	unformatted, err := a.output(ctx, a.Root, nil, "gofmt", "-l", "tools")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(unformatted)) != "" {
		return fmt.Errorf("Go files are not formatted:\n%s", unformatted)
	}
	for _, args := range [][]string{{"vet", "./..."}, {"test", "-race", "-count=1", "./..."}} {
		if err := a.run(ctx, filepath.Join(a.Root, "tools"), nil, "go", args...); err != nil {
			return err
		}
	}
	if err := a.agentSetupCheck(ctx, false); err != nil {
		return err
	}
	scripts, err := a.trackedShellFiles(ctx)
	if err != nil {
		return err
	}
	if len(scripts) > 0 {
		if err := a.run(ctx, a.Root, nil, "shellcheck", scripts...); err != nil {
			return err
		}
		for _, script := range scripts {
			if err := a.run(ctx, a.Root, nil, "bash", "-n", script); err != nil {
				return err
			}
		}
	}
	fmt.Fprintln(a.Out, "development tooling checks passed")
	return nil
}

func (a *App) trackedShellFiles(ctx context.Context) ([]string, error) {
	data, err := a.output(ctx, a.Root, nil, "git", "ls-files", "-z", "--", ".shell", "dev")
	if err != nil {
		return nil, err
	}
	var scripts []string
	for _, path := range nulFields(data) {
		if path != ".shell" && path != "dev/run" && filepath.Ext(path) != ".sh" {
			continue
		}
		if info, statErr := os.Stat(filepath.Join(a.Root, filepath.FromSlash(path))); statErr == nil && !info.IsDir() {
			scripts = append(scripts, path)
		}
	}
	return scripts, nil
}

func (a *App) portalFeedback(ctx context.Context, level string, args []string) error {
	if len(args) == 0 {
		return usage("usage: dev/run %s <target>", level)
	}
	target, rest := args[0], args[1:]
	switch level + ":" + target {
	case "check:changed":
		if len(rest) != 0 {
			return usage("usage: dev/run check changed")
		}
		return a.changedPortalCheck(ctx)
	case "check:portal":
		if len(rest) != 0 {
			return usage("usage: dev/run check portal")
		}
		for _, arguments := range [][]string{{"compile", "--warnings-as-errors"}, {"format", "--check-formatted"}, {"credo"}} {
			if err := a.run(ctx, a.Portal, nil, "mix", arguments...); err != nil {
				return err
			}
		}
		return nil
	case "check:staged":
		if len(rest) != 0 {
			return usage("usage: dev/run check staged")
		}
		return a.stagedCheck(ctx)
	case "check:infra-templates":
		if len(rest) != 0 {
			return usage("usage: dev/run check infra-templates")
		}
		return a.infraOps(ctx, []string{"validate-templates"})
	case "check:pack-environment":
		if len(rest) > 2 {
			return usage("usage: dev/run check pack-environment [repo] [environment]")
		}
		return a.infraOps(ctx, append([]string{"verify-pack-environment"}, rest...))
	case "check:tooling":
		if len(rest) != 0 {
			return usage("usage: dev/run check tooling")
		}
		return a.toolingCheck(ctx)
	case "check:agent-setup":
		if len(rest) != 0 {
			return usage("usage: dev/run check agent-setup")
		}
		return a.agentSetupCheck(ctx, true)
	case "test:portal":
		if len(rest) == 0 {
			return usage("usage: dev/run test portal <paths...|--stale|--failed>")
		}
		_, env, err := a.up(ctx)
		if err != nil {
			return err
		}
		return a.portalTests(ctx, env, rest)
	case "gate:portal":
		if len(rest) != 0 {
			return usage("usage: dev/run gate portal")
		}
		var env map[string]string
		if os.Getenv("CI") == "" {
			_, workspaceEnv, err := a.up(ctx)
			if err != nil {
				return err
			}
			env = workspaceEnv
		} else if os.Getenv("DATABASE_URL") == "" {
			return fmt.Errorf("CI portal gate requires DATABASE_URL")
		}
		for _, arguments := range [][]string{{"compile", "--warnings-as-errors"}, {"format", "--check-formatted"}, {"credo"}} {
			if err := a.run(ctx, a.Portal, env, "mix", arguments...); err != nil {
				return err
			}
		}
		return a.portalTestOutput(ctx, env)
	default:
		return usage("usage: dev/run %s <changed|portal|staged|infra-templates|pack-environment|agent-setup|tooling>", level)
	}
}
