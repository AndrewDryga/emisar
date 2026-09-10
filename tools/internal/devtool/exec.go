package devtool

import (
	"context"
	"io"
)

// The lowercase names every phase in this package calls; the behaviour lives
// in toolutil.Runner, shared with infraops.
func (a *App) run(ctx context.Context, dir string, env map[string]string, name string, args ...string) error {
	return a.Runner.Run(ctx, dir, env, name, args...)
}

func (a *App) output(ctx context.Context, dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	return a.Runner.Output(ctx, dir, env, name, args...)
}

func copyOutput(dst io.Writer, data []byte) {
	_, _ = dst.Write(data)
}
