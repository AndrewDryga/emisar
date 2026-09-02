package devtool

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const frozenMigration = "portal/apps/emisar/priv/repo/migrations/20260101000000_frozen.exs"

func TestPortalGateRejectsCommittedMigrationRangeEdit(t *testing.T) {
	root, migration, base := newFrozenMigrationRepo(t)
	writeFrozenFixture(t, root, migration, "defmodule FrozenChanged do\nend\n")
	runFrozenGit(t, root, "add", migration)
	runFrozenGit(t, root, "commit", "--quiet", "-m", "edit frozen migration")

	t.Setenv("CI", "true")
	t.Setenv("DATABASE_URL", "postgres://unused")
	t.Setenv("EMISAR_FROZEN_MIGRATIONS_EVENT", "push")
	t.Setenv("EMISAR_FROZEN_MIGRATIONS_BASE", base)
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	err := app.portalGate(context.Background())
	if err == nil || !strings.Contains(err.Error(), "committed migrations are frozen") {
		t.Fatalf("Portal gate migration error = %v", err)
	}
}

func TestPortalGateRejectsUnstagedMigrationEdit(t *testing.T) {
	root, migration, _ := newFrozenMigrationRepo(t)
	writeFrozenFixture(t, root, migration, "defmodule FrozenChanged do\nend\n")

	t.Setenv("CI", "")
	t.Setenv("EMISAR_FROZEN_MIGRATIONS_EVENT", "")
	t.Setenv("EMISAR_FROZEN_MIGRATIONS_BASE", "")
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	err := app.portalGate(context.Background())
	if err == nil || !strings.Contains(err.Error(), "editing or deleting a committed migration is forbidden") {
		t.Fatalf("Portal gate migration error = %v", err)
	}
}

func TestLocalFrozenMigrationsChecksIndexAndAllowsNewFiles(t *testing.T) {
	t.Run("staged edit fails", func(t *testing.T) {
		root, migration, _ := newFrozenMigrationRepo(t)
		writeFrozenFixture(t, root, migration, "defmodule FrozenChanged do\nend\n")
		runFrozenGit(t, root, "add", migration)

		app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
		err := app.checkLocalFrozenMigrations(context.Background())
		if err == nil || !strings.Contains(err.Error(), migration) {
			t.Fatalf("staged migration error = %v", err)
		}
	})

	t.Run("new migration passes", func(t *testing.T) {
		root, _, _ := newFrozenMigrationRepo(t)
		added := "portal/apps/emisar/priv/repo/migrations/20260102000000_forward.exs"
		writeFrozenFixture(t, root, added, "defmodule Forward do\nend\n")
		runFrozenGit(t, root, "add", added)

		app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
		if err := app.checkLocalFrozenMigrations(context.Background()); err != nil {
			t.Fatalf("new migration rejected: %v", err)
		}
	})
}

func TestFrozenMigrationCIInputsFailClosed(t *testing.T) {
	for _, test := range []struct {
		name  string
		event string
		base  string
	}{
		{name: "neither"},
		{name: "event only", event: "push"},
		{name: "base only", base: strings.Repeat("a", 40)},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("CI", "true")
			t.Setenv("EMISAR_FROZEN_MIGRATIONS_EVENT", test.event)
			t.Setenv("EMISAR_FROZEN_MIGRATIONS_BASE", test.base)
			app := New(t.TempDir(), strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
			err := app.checkFrozenMigrations(context.Background())
			if err == nil || !strings.Contains(err.Error(), "EMISAR_FROZEN_MIGRATIONS_EVENT") ||
				!strings.Contains(err.Error(), "EMISAR_FROZEN_MIGRATIONS_BASE") {
				t.Fatalf("incomplete input error = %v", err)
			}
		})
	}
}

func newFrozenMigrationRepo(t *testing.T) (root, migration, base string) {
	t.Helper()
	root = t.TempDir()
	runFrozenGit(t, root, "init", "--quiet")
	runFrozenGit(t, root, "config", "user.email", "test@example.invalid")
	runFrozenGit(t, root, "config", "user.name", "Test")
	migration = frozenMigration
	writeFrozenFixture(t, root, migration, "defmodule Frozen do\nend\n")
	runFrozenGit(t, root, "add", migration)
	runFrozenGit(t, root, "commit", "--quiet", "-m", "frozen migration")
	base = strings.TrimSpace(runFrozenGit(t, root, "rev-parse", "HEAD"))
	return root, migration, base
}

func writeFrozenFixture(t *testing.T, root, path, body string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func runFrozenGit(t *testing.T, root string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = root
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v (%s)", strings.Join(args, " "), err, output)
	}
	return string(output)
}
