package devtool

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

func (a *App) command(ctx context.Context, dir string, env map[string]string, name string, args ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Stdin = a.In
	command.Stdout = a.Out
	command.Stderr = a.Err
	command.Env = toolutil.MergedEnv(env)
	return command
}

func (a *App) run(ctx context.Context, dir string, env map[string]string, name string, args ...string) error {
	if _, err := exec.LookPath(name); err != nil {
		return fmt.Errorf("missing %s", name)
	}
	if err := a.command(ctx, dir, env, name, args...).Run(); err != nil {
		return fmt.Errorf("%s: %w", strings.Join(append([]string{name}, args...), " "), err)
	}
	return nil
}

func (a *App) output(ctx context.Context, dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	if _, err := exec.LookPath(name); err != nil {
		return nil, fmt.Errorf("missing %s", name)
	}
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = toolutil.MergedEnv(env)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return nil, fmt.Errorf("%s: %w (%s)", strings.Join(append([]string{name}, args...), " "), err, message)
		}
		return nil, fmt.Errorf("%s: %w", strings.Join(append([]string{name}, args...), " "), err)
	}
	return stdout.Bytes(), nil
}

func copyOutput(dst io.Writer, data []byte) {
	_, _ = dst.Write(data)
}
