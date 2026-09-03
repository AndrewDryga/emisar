// Command releaseenv verifies one named GitHub release environment.
package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"

	"github.com/andrewdryga/emisar/tools/internal/releaseenv"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: releaseenv <owner/repo> <environment>")
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := releaseenv.Verify(ctx, os.Args[1], os.Args[2], fetchGitHub, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "releaseenv:", err)
		os.Exit(1)
	}
}

func fetchGitHub(ctx context.Context, path string) ([]byte, error) {
	command := exec.CommandContext(ctx, "gh", "api",
		"-H", "Accept: application/vnd.github+json",
		"-H", "X-GitHub-Api-Version: 2022-11-28",
		path)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		if message := strings.TrimSpace(stderr.String()); message != "" {
			return nil, fmt.Errorf("gh api %s: %w: %s", path, err, message)
		}
		return nil, fmt.Errorf("gh api %s: %w", path, err)
	}
	return stdout.Bytes(), nil
}
