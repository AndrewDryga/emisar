package devtool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const portalMigrationsDir = "portal/apps/emisar/priv/repo/migrations"

var migrationFilename = regexp.MustCompile(`^(\d{14})_[a-z0-9_]+\.exs$`)

// Production applies whatever is unapplied, in whatever order, so a migration
// whose version sorts before ones that already ran still lands there. A fresh
// database is where the order matters: it runs the files by version, and a
// late-added migration with an early version runs before tables it depends
// on. The committed versions are a hand-kept counter that ran ahead of the
// calendar, so `mix ecto.gen.migration`'s real timestamp already sorts before
// dozens of shipped files. Every migration that is not yet on origin/main
// therefore has to carry a version greater than every one that is.
func (a *App) checkNewMigrationsSortLast(ctx context.Context) error {
	entries, err := os.ReadDir(filepath.Join(a.Root, filepath.FromSlash(portalMigrationsDir)))
	if err != nil {
		return err
	}
	working := map[string]string{}
	for _, entry := range entries {
		// Ecto ignores dotfiles here (`.formatter.exs` lives beside the migrations).
		if entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		match := migrationFilename.FindStringSubmatch(entry.Name())
		if match == nil {
			return fmt.Errorf("%s/%s: migration files are <14-digit version>_<snake_case_name>.exs", portalMigrationsDir, entry.Name())
		}
		working[entry.Name()] = match[1]
	}
	if len(working) == 0 {
		return fmt.Errorf("%s holds no migrations", portalMigrationsDir)
	}

	committed, err := a.output(ctx, a.Root, nil, "git", "ls-tree", "-r", "--name-only", "origin/main", "--", portalMigrationsDir)
	if err != nil {
		if strings.Contains(err.Error(), "Not a valid object name") || strings.Contains(err.Error(), "unknown revision") {
			fmt.Fprintln(a.Out, "skipped: no origin/main in this clone, so new migrations cannot be compared with the committed set")
			return nil
		}
		return fmt.Errorf("listing committed migrations: %w", err)
	}
	baselineMax := ""
	baseline := map[string]bool{}
	for _, path := range strings.Fields(string(committed)) {
		name := filepath.Base(path)
		baseline[name] = true
		if match := migrationFilename.FindStringSubmatch(name); match != nil && match[1] > baselineMax {
			baselineMax = match[1]
		}
	}

	var added []string
	for name := range working {
		if !baseline[name] {
			added = append(added, name)
		}
	}
	sort.Strings(added)
	var problems []string
	for _, name := range added {
		if working[name] <= baselineMax {
			problems = append(problems, fmt.Sprintf("%s sorts at or before the newest committed migration (%s); give it a version above that",
				name, baselineMax))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("new migrations must sort after every committed one:\n  %s", strings.Join(problems, "\n  "))
	}
	if len(added) == 0 {
		fmt.Fprintln(a.Out, "verified: no migrations beyond origin/main")
	} else {
		fmt.Fprintf(a.Out, "verified: %d new migration(s) sort after the newest committed one (%s)\n", len(added), baselineMax)
	}
	return nil
}
