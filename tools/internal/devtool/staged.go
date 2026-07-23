package devtool

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/packhash"
)

func (a *App) stagedFiles(ctx context.Context, filters []string, paths ...string) ([]string, error) {
	args := []string{"diff", "--cached", "--name-only", "-z"}
	if len(filters) != 0 {
		args = append(args, "--diff-filter="+strings.Join(filters, ""))
	}
	args = append(args, "--")
	args = append(args, paths...)
	output, err := a.output(ctx, a.Root, nil, "git", args...)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, entry := range bytes.Split(output, []byte{0}) {
		if len(entry) != 0 {
			files = append(files, string(entry))
		}
	}
	return files, nil
}

func (a *App) stagedBlob(ctx context.Context, path string) ([]byte, error) {
	return a.output(ctx, a.Root, nil, "git", "show", ":"+path)
}

func formatInput(ctx context.Context, name string, args []string, source []byte) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Stdin = bytes.NewReader(source)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

func (a *App) requireCleanPackHashInputs(ctx context.Context) error {
	paths := []string{
		"packs/redis", "packs/cassandra",
		"portal/apps/emisar_web/test/emisar_web/packs_test.exs",
	}
	unstaged, err := a.output(ctx, a.Root, nil, "git",
		append([]string{"diff", "--name-only", "-z", "--"}, paths...)...)
	if err != nil {
		return err
	}
	untracked, err := a.output(ctx, a.Root, nil, "git",
		append([]string{"ls-files", "--others", "--exclude-standard", "-z", "--"}, paths...)...)
	if err != nil {
		return err
	}
	files := append(nulFields(unstaged), nulFields(untracked)...)
	if len(files) != 0 {
		return fmt.Errorf(
			"pack hash validation requires all redis, cassandra, and golden changes staged:\n  %s",
			strings.Join(files, "\n  "),
		)
	}
	return nil
}

func (a *App) stagedCheck(ctx context.Context) error {
	migrations, err := a.stagedFiles(ctx, []string{"M", "D", "R"}, "*priv/repo/migrations/*.exs")
	if err != nil {
		return err
	}
	if len(migrations) != 0 {
		return fmt.Errorf("editing or deleting a committed migration is forbidden:\n  %s\nadd a new forward migration instead",
			strings.Join(migrations, "\n  "))
	}

	packFiles, err := a.stagedFiles(ctx, []string{"A", "C", "M", "R"}, "packs/redis", "packs/cassandra")
	if err != nil {
		return err
	}
	if len(packFiles) != 0 {
		if err := a.requireCleanPackHashInputs(ctx); err != nil {
			return err
		}
		err := packhash.Check(a.Root, "", false, a.Out)
		if errors.Is(err, packhash.ErrUnavailable) {
			fmt.Fprintln(a.Err, "commit check: pack hash validation skipped:", err)
		} else if err != nil {
			return err
		}
	}

	terraformFiles, err := a.stagedFiles(ctx, []string{"A", "C", "M"}, "*.tf")
	if err != nil {
		return err
	}
	if len(terraformFiles) != 0 {
		if _, err := exec.LookPath("terraform"); err == nil {
			for _, file := range terraformFiles {
				source, err := a.stagedBlob(ctx, file)
				if err != nil {
					return err
				}
				formatted, err := formatInput(ctx, "terraform", []string{"fmt", "-no-color", "-"}, source)
				if err != nil {
					return fmt.Errorf("formatting staged Terraform %s: %w", file, err)
				}
				if !bytes.Equal(source, formatted) {
					return fmt.Errorf("staged Terraform file is not formatted: %s", file)
				}
			}
		}
	}

	goFiles, err := a.stagedFiles(ctx, []string{"A", "C", "M"}, "*.go")
	if err != nil {
		return err
	}
	if len(goFiles) != 0 {
		if _, err := exec.LookPath("gofmt"); err == nil {
			var unformatted []string
			for _, file := range goFiles {
				source, err := a.stagedBlob(ctx, file)
				if err != nil {
					return err
				}
				formatted, err := formatInput(ctx, "gofmt", []string{"-s"}, source)
				if err != nil {
					return fmt.Errorf("formatting staged Go %s: %w", file, err)
				}
				if !bytes.Equal(source, formatted) {
					unformatted = append(unformatted, file)
				}
			}
			if len(unformatted) != 0 {
				return fmt.Errorf("staged Go files are not formatted:\n%s", strings.Join(unformatted, "\n"))
			}
		}
	}
	return nil
}
