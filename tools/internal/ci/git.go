package ci

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

const zeroCommit = "0000000000000000000000000000000000000000"

func git(ctx context.Context, root string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = root
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return nil, fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, message)
		}
		return nil, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return stdout.Bytes(), nil
}

func validBase(ctx context.Context, root, base string) bool {
	if base == "" || base == zeroCommit {
		return false
	}
	_, err := git(ctx, root, "cat-file", "-e", base+"^{commit}")
	return err == nil
}

func diffBase(ctx context.Context, root, event, base string) (string, error) {
	if event != "pull_request" {
		return base, nil
	}
	result, err := git(ctx, root, "merge-base", base, "HEAD")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(result)), nil
}
