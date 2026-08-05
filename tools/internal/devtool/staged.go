package devtool

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/packhash"
)

func (a *App) workingTreeFiles(ctx context.Context, filters []string, paths ...string) ([]string, error) {
	return a.diffFiles(ctx, []string{"diff", "--name-only", "-z"}, filters, paths...)
}

func (a *App) stagedFiles(ctx context.Context, filters []string, paths ...string) ([]string, error) {
	return a.diffFiles(ctx, []string{"diff", "--cached", "--name-only", "-z"}, filters, paths...)
}

func (a *App) diffFiles(ctx context.Context, base []string, filters []string, paths ...string) ([]string, error) {
	args := append([]string{}, base...)
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

func (a *App) checkStagedPortalFormat(ctx context.Context) error {
	files, err := a.stagedFiles(ctx, []string{"A", "C", "M", "R"}, "portal")
	if err != nil {
		return err
	}
	var formatFiles []string
	for _, file := range files {
		switch filepath.Ext(file) {
		case ".ex", ".exs", ".heex":
			formatFiles = append(formatFiles, file)
		}
	}
	if len(formatFiles) == 0 {
		return nil
	}
	if _, err := exec.LookPath("mix"); err != nil {
		return fmt.Errorf("staged Portal files require mix: %w", err)
	}

	var unformatted []string
	for _, file := range formatFiles {
		source, err := a.stagedBlob(ctx, file)
		if err != nil {
			return err
		}
		relative := strings.TrimPrefix(filepath.ToSlash(file), "portal/")
		command := exec.CommandContext(ctx, "mix", "format", "--check-formatted", "--stdin-filename", relative, "-")
		command.Dir = a.Portal
		command.Env = os.Environ()
		command.Stdin = bytes.NewReader(source)
		var output bytes.Buffer
		command.Stdout, command.Stderr = &output, &output
		if err := command.Run(); err != nil {
			if strings.Contains(output.String(), "not formatted") {
				unformatted = append(unformatted, file)
				continue
			}
			return fmt.Errorf("formatting staged Portal %s: %w: %s", file, err, strings.TrimSpace(output.String()))
		}
	}
	if len(unformatted) != 0 {
		return fmt.Errorf("staged Portal files are not formatted:\n%s\nrun: cd portal && mix format",
			strings.Join(unformatted, "\n"))
	}
	return nil
}

func (a *App) requireCleanPackHashInputs(ctx context.Context) error {
	paths := []string{
		"packs/redis", "packs/cassandra",
		"portal/apps/emisar/test/emisar/catalog/published_registry_test.exs",
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

// A committed migration has already run in production; editing it diverges
// prod's schema. This is the check that stops that, so it looks at the WORKING
// TREE as well as the index.
//
// Two ways the index alone missed it. `git commit -a` stages tracked
// modifications as part of the commit, after this hook has already run, so the
// edit was invisible; so was `git commit <path>`. And a migration sitting
// modified in the working tree is a mistake whether or not this particular
// commit carries it — saying so now beats saying so after it ships.
//
// T (typechange) counts with M/D/R: swapping a migration for a symlink replaces
// its contents just as thoroughly.
func (a *App) touchedMigrations(ctx context.Context) ([]string, error) {
	// Timestamp-prefixed files only: `.formatter.exs` lives in the same directory
	// and is not a migration.
	const glob = "*priv/repo/migrations/[0-9]*.exs"
	filters := []string{"M", "D", "R", "T"}

	staged, err := a.stagedFiles(ctx, filters, glob)
	if err != nil {
		return nil, err
	}
	unstaged, err := a.workingTreeFiles(ctx, filters, glob)
	if err != nil {
		return nil, err
	}

	seen := make(map[string]bool, len(staged)+len(unstaged))
	union := make([]string, 0, len(staged)+len(unstaged))
	for _, file := range append(staged, unstaged...) {
		if !seen[file] {
			seen[file] = true
			union = append(union, file)
		}
	}
	return union, nil
}

func (a *App) stagedCheck(ctx context.Context) error {
	migrations, err := a.touchedMigrations(ctx)
	if err != nil {
		return err
	}
	if len(migrations) != 0 {
		return fmt.Errorf("editing or deleting a committed migration is forbidden:\n  %s\nadd a new forward migration instead",
			strings.Join(migrations, "\n  "))
	}
	if err := a.checkStagedPortalFormat(ctx); err != nil {
		return err
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
