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

// A clone with an origin/main ref carrying the committed migrations, plus
// whatever extra files each case adds to the working tree afterwards.
func writeMigrationFixtures(t *testing.T, committed []string, added []string) *App {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, filepath.FromSlash(portalMigrationsDir))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
	}
	git("init", "-q")
	git("config", "user.email", "test@example.com")
	git("config", "user.name", "Test")
	git("config", "commit.gpgsign", "false")
	for _, name := range committed {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("defmodule M do end\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	git("add", ".")
	git("commit", "-q", "-m", "committed migrations")
	git("update-ref", "refs/remotes/origin/main", "HEAD")
	for _, name := range added {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("defmodule M do end\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckNewMigrationsSortLast(t *testing.T) {
	ctx := context.Background()
	committed := []string{
		"20261030000000_record_runner_token_replacements.exs",
		"20261101000000_allow_independent_group_access_additions.exs",
	}

	// Nothing new: vacuously fine.
	app := writeMigrationFixtures(t, committed, nil)
	if err := app.checkNewMigrationsSortLast(ctx); err != nil {
		t.Fatal(err)
	}

	// The counter convention continued.
	app = writeMigrationFixtures(t, committed, []string{"20261102000000_add_widgets.exs"})
	if err := app.checkNewMigrationsSortLast(ctx); err != nil {
		t.Fatal(err)
	}
	if out := app.Out.(*bytes.Buffer).String(); !strings.Contains(out, "1 new migration(s) sort after the newest committed one (20261101000000)") {
		t.Fatalf("unexpected report: %q", out)
	}

	// The failure this check exists for: a real `mix ecto.gen.migration`
	// timestamp from today, which sorts before dozens of shipped files.
	err := writeMigrationFixtures(t, committed, []string{"20260910183000_add_widgets.exs"}).checkNewMigrationsSortLast(ctx)
	if err == nil || !strings.Contains(err.Error(), "20260910183000_add_widgets.exs sorts at or before the newest committed migration (20261101000000)") {
		t.Fatalf("early version not reported: %v", err)
	}

	// Equal is not greater either.
	err = writeMigrationFixtures(t, committed, []string{"20261101000000_something_else.exs"}).checkNewMigrationsSortLast(ctx)
	if err == nil || !strings.Contains(err.Error(), "20261101000000_something_else.exs sorts at or before") {
		t.Fatalf("equal version not reported: %v", err)
	}

	// A file that is not a migration at all is a hard error, not silently skipped.
	err = writeMigrationFixtures(t, committed, []string{"notes.txt"}).checkNewMigrationsSortLast(ctx)
	if err == nil || !strings.Contains(err.Error(), "notes.txt: migration files are") {
		t.Fatalf("stray file not reported: %v", err)
	}
}
