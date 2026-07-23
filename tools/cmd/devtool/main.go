// Command devtool implements the repository's development workflows. The
// public entrypoint is the root ./run bootstrap.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/andrewdryga/emisar/tools/internal/devtool"
	"github.com/andrewdryga/emisar/tools/internal/repo"
)

func main() {
	root, err := repo.Root()
	if err != nil {
		fmt.Fprintln(os.Stderr, "./run:", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()

	app := devtool.New(root, os.Stdin, os.Stdout, os.Stderr)
	if err := app.Run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "./run:", err)
		if devtool.IsUsage(err) {
			os.Exit(2)
		}
		os.Exit(devtool.ExitCode(err))
	}
}
