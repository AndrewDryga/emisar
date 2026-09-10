package toolutil

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// Runner is the one way tooling packages start child processes: a looked-up
// binary, a merged environment, and one error shape for every failure. Two
// packages had carried their own copies of these three methods, and the copies
// had drifted in the error text, in whether a whitespace-only stderr counted,
// and in whether a missing binary could be simulated in a test.
type Runner struct {
	In  io.Reader
	Out io.Writer
	Err io.Writer
	// LookPath resolves a binary; nil means exec.LookPath. A test sets it to
	// simulate a tool that is not installed.
	LookPath func(string) (string, error)
}

func (r *Runner) lookPath(name string) (string, error) {
	if r.LookPath != nil {
		return r.LookPath(name)
	}
	return exec.LookPath(name)
}

// Require fails with one clear sentence per binary that is not installed.
func (r *Runner) Require(names ...string) error {
	for _, name := range names {
		if _, err := r.lookPath(name); err != nil {
			return fmt.Errorf("%s is required but not installed", name)
		}
	}
	return nil
}

// Command builds a child wired to the Runner's streams with `env` applied over
// the current environment.
func (r *Runner) Command(ctx context.Context, dir string, env map[string]string, name string, args ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = MergedEnv(env)
	command.Stdin = r.In
	command.Stdout = r.Out
	command.Stderr = r.Err
	return command
}

// Run executes a child on the Runner's streams and reports a failure as
// `name args: err`.
func (r *Runner) Run(ctx context.Context, dir string, env map[string]string, name string, args ...string) error {
	if err := r.Require(name); err != nil {
		return err
	}
	if err := r.Command(ctx, dir, env, name, args...).Run(); err != nil {
		return fmt.Errorf("%s: %w", commandLine(name, args), err)
	}
	return nil
}

// Output captures a child's stdout and reports a failure as `name args: err`,
// followed by the child's stderr when it said anything.
func (r *Runner) Output(ctx context.Context, dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	if err := r.Require(name); err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Env = MergedEnv(env)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		if message := strings.TrimSpace(stderr.String()); message != "" {
			return nil, fmt.Errorf("%s: %w: %s", commandLine(name, args), err, message)
		}
		return nil, fmt.Errorf("%s: %w", commandLine(name, args), err)
	}
	return stdout.Bytes(), nil
}

func commandLine(name string, args []string) string {
	return strings.Join(append([]string{name}, args...), " ")
}
