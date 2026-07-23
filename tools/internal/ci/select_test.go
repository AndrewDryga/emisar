package ci

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestSelectAndFrozenMigrations(t *testing.T) {
	root := newGitRepo(t)
	migration := "portal/apps/emisar/priv/repo/migrations/20260101000000_old.exs"
	writeFixture(t, root, migration, "defmodule Old do\nend\n")
	writeFixture(t, root, "runner/old.go", "package main\n")
	commitAll(t, root, "base")
	base := gitText(t, root, "rev-parse", "HEAD")

	t.Run("migration rename selects portal and fails freeze", func(t *testing.T) {
		runGit(t, root, "mv", migration, "old.exs")
		commitAll(t, root, "rename")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Portal {
			t.Fatal("deleted portal migration did not select portal")
		}
		if err := CheckFrozenMigrations(context.Background(), root, "push", base); err == nil {
			t.Fatal("migration rename passed frozen migration check")
		}
		resetHard(t, root, base)
	})

	t.Run("newline path remains one runner path", func(t *testing.T) {
		writeFixture(t, root, "runner/line\nbreak.go", "package main\n")
		commitAll(t, root, "newline")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if got := selection.GoModules(); len(got) != 1 || got[0] != "runner" {
			t.Fatalf("GoModules() = %q, want runner only", got)
		}
		resetHard(t, root, base)
	})

	t.Run("new migration is allowed", func(t *testing.T) {
		writeFixture(t, root, "portal/apps/emisar/priv/repo/migrations/20260102000000_new.exs", "defmodule New do\nend\n")
		commitAll(t, root, "new migration")
		if err := CheckFrozenMigrations(context.Background(), root, "push", base); err != nil {
			t.Fatal(err)
		}
		resetHard(t, root, base)
	})

	t.Run("workflow pull request validates without release", func(t *testing.T) {
		writeFixture(t, root, ".github/workflows/cd.yml", "name: CD\n")
		commitAll(t, root, "workflow")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Workflows || !selection.Portal || !selection.Runner || !selection.MCP || !selection.Tools || !selection.Packs || !selection.Infra || !selection.Deps || !selection.MCPListing {
			t.Fatalf("workflow selection is incomplete: %+v", selection)
		}
		if selection.PortalRelease || selection.PacksRelease {
			t.Fatalf("workflow-only PR selected release: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("infra push publishes portal but not packs", func(t *testing.T) {
		writeFixture(t, root, "infra/packs/emisar-admin/pack.yaml", "schema_version: 1\n")
		commitAll(t, root, "infra")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Infra || !selection.Portal || !selection.PortalRelease || selection.PacksRelease {
			t.Fatalf("infra push selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("installer selects portal not infra", func(t *testing.T) {
		writeFixture(t, root, "install.sh", "#!/bin/sh\n")
		commitAll(t, root, "installer")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Portal || !selection.PortalRelease || selection.Infra {
			t.Fatalf("installer selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("terraform lock is infra not dependency age", func(t *testing.T) {
		writeFixture(t, root, "infra/.terraform.lock.hcl", "provider lock\n")
		commitAll(t, root, "terraform lock")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Infra || selection.Deps {
			t.Fatalf("terraform lock selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	for _, path := range []string{"run", ".agent/loop.yaml"} {
		t.Run(path+" selects tools", func(t *testing.T) {
			writeFixture(t, root, path, "fixture\n")
			commitAll(t, root, path)
			selection, err := Select(context.Background(), root, "push", base)
			if err != nil {
				t.Fatal(err)
			}
			if got := selection.GoModules(); len(got) != 1 || got[0] != "tools" {
				t.Fatalf("GoModules() = %q, want tools only", got)
			}
			resetHard(t, root, base)
		})
	}
}

func newGitRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	runGit(t, root, "init", "-q")
	runGit(t, root, "config", "user.name", "test")
	runGit(t, root, "config", "user.email", "test@example.com")
	return root
}

func writeFixture(t *testing.T, root, name, contents string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func commitAll(t *testing.T, root, message string) {
	t.Helper()
	runGit(t, root, "add", "-A")
	runGit(t, root, "commit", "-qm", message)
}

func resetHard(t *testing.T, root, revision string) {
	t.Helper()
	runGit(t, root, "reset", "--hard", "-q", revision)
	runGit(t, root, "clean", "-fdq")
}

func gitText(t *testing.T, root string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = root
	data, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(data[:len(data)-1])
}

func runGit(t *testing.T, root string, args ...string) {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
}
