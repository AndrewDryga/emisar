package ci

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSelectAndFrozenMigrations(t *testing.T) {
	root := newGitRepo(t)
	migration := "portal/apps/emisar/priv/repo/migrations/20260101000000_old.exs"
	writeFixture(t, root, migration, "defmodule Old do\nend\n")
	writeFixture(t, root, "runner/old.go", "package main\n")
	writeFixture(t, root, "packs/postgres/test/cases.yaml", behaviorPlan("postgres",
		versionRow("18.4", "a", true),
		versionRow("17.6", "b", false),
	))
	writeFixture(t, root, "packs/mysql/test/cases.yaml", behaviorPlan("mysql",
		versionRow("9.7.1", "c", true),
	))
	writeFixture(t, root, "runner/release/container-packs.txt", "# baked packs\nmysql\n")
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
		if !selection.Workflows || !selection.Portal || !selection.Runner || !selection.MCP || !selection.Tools || !selection.Packs || !selection.Infra || !selection.Deps || !selection.MCPListing || !selection.RunnerImage {
			t.Fatalf("workflow selection is incomplete: %+v", selection)
		}
		if selection.PortalRelease || selection.PacksRelease {
			t.Fatalf("workflow-only PR selected release: %+v", selection)
		}
		if len(selection.PackBehavior) != 3 || !selection.SigningE2E || !selection.SSOE2E {
			t.Fatalf("workflow selection omitted integration gates: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("pack change selects only its behavior plan", func(t *testing.T) {
		writeFixture(t, root, "packs/postgres/actions/uptime.yaml", "id: postgres.uptime\n")
		commitAll(t, root, "postgres")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 2 ||
			selection.PackBehavior[0].Pack != "postgres" ||
			selection.PackBehavior[0].Version != "18.4" ||
			selection.PackBehavior[1].Version != "17.6" {
			t.Fatalf("pack behavior selection = %v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("runner source selects the container image", func(t *testing.T) {
		writeFixture(t, root, "runner/doctor.go", "package main\n")
		commitAll(t, root, "runner source")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.RunnerImage {
			t.Fatalf("runner/ change did not select the image: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("only a baked pack selects the container image", func(t *testing.T) {
		writeFixture(t, root, "packs/mysql/actions/uptime.yaml", "id: mysql.uptime\n")
		commitAll(t, root, "baked pack")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.RunnerImage {
			t.Fatalf("baked pack change did not select the image: %+v", selection)
		}
		resetHard(t, root, base)

		writeFixture(t, root, "packs/postgres/actions/uptime.yaml", "id: postgres.uptime\n")
		commitAll(t, root, "unbaked pack")
		selection, err = Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if selection.RunnerImage {
			t.Fatalf("unbaked pack change selected the image: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("changed risky action needs behavior or exception", func(t *testing.T) {
		writeFixture(t, root, "packs/postgres/actions/restart.yaml", "id: postgres.restart\nrisk: high\n")
		commitAll(t, root, "unaccounted risk")
		if _, err := Select(context.Background(), root, "pull_request", base); err == nil ||
			!strings.Contains(err.Error(), "needs a successful behavior case or risk exception") {
			t.Fatalf("unaccounted risky action error = %v", err)
		}
		resetHard(t, root, base)

		writeFixture(t, root, "packs/postgres/actions/restart.yaml", "id: postgres.restart\nrisk: high\n")
		writeFixture(t, root, "packs/postgres/test/cases.yaml", behaviorPlan("postgres",
			versionRow("18.4", "a", true),
			versionRow("17.6", "b", false),
		)+"risk_accountability:\n  exceptions:\n    postgres.restart: requires_cluster\n")
		commitAll(t, root, "accounted risk")
		if _, err := Select(context.Background(), root, "pull_request", base); err != nil {
			t.Fatalf("accounted risky action rejected: %v", err)
		}
		resetHard(t, root, base)
	})

	t.Run("pack without plan remains contract only", func(t *testing.T) {
		writeFixture(t, root, "packs/host-only/actions/status.yaml", "id: host.status\n")
		commitAll(t, root, "host only")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 0 || !selection.Packs {
			t.Fatalf("contract-only selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("shared pack harness selects every plan", func(t *testing.T) {
		writeFixture(t, root, "tools/internal/packtest/packtest.go", "package packtest\n")
		commitAll(t, root, "harness")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 3 {
			t.Fatalf("shared harness selection = %v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("e2e paths select their scenario", func(t *testing.T) {
		writeFixture(t, root, "tools/cmd/signing-e2e/main.go", "package main\n")
		commitAll(t, root, "signing")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.SigningE2E || selection.SSOE2E {
			t.Fatalf("signing selection = %+v", selection)
		}
		resetHard(t, root, base)

		writeFixture(t, root, "dev/keycloak/realm.json", "{}\n")
		commitAll(t, root, "sso")
		selection, err = Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if selection.SigningE2E || !selection.SSOE2E {
			t.Fatalf("SSO selection = %+v", selection)
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

func TestSelectPacksReleaseDrift(t *testing.T) {
	committedCatalog := `{"schema_version":1,"packs":[]}` + "\n"
	catalogPath := "portal/apps/emisar/priv/packs/catalog.json"
	root := newGitRepo(t)
	writeFixture(t, root, catalogPath, committedCatalog)
	writeFixture(t, root, "docs.md", "docs\n")
	writeFixture(t, root, "packs/postgres/test/cases.yaml", behaviorPlan("postgres",
		versionRow("18.4", "a", true),
	))
	commitAll(t, root, "base")
	base := gitText(t, root, "rev-parse", "HEAD")

	var requests atomic.Int32
	var liveStatus atomic.Int32
	var liveCatalog atomic.Value
	liveStatus.Store(http.StatusOK)
	liveCatalog.Store(committedCatalog)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(int(liveStatus.Load()))
		w.Write([]byte(liveCatalog.Load().(string)))
	}))
	t.Cleanup(server.Close)
	previousURL := publishedCatalogURL
	publishedCatalogURL = server.URL
	t.Cleanup(func() { publishedCatalogURL = previousURL })

	pushWithoutPackDiff := func(t *testing.T) Selection {
		t.Helper()
		writeFixture(t, root, "docs.md", "docs for "+t.Name()+"\n")
		commitAll(t, root, "docs")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		return selection
	}

	t.Run("matching live catalog stays skipped", func(t *testing.T) {
		requests.Store(0)
		selection := pushWithoutPackDiff(t)
		if selection.PacksRelease || selection.Packs {
			t.Fatalf("matching catalog selected a release: %+v", selection)
		}
		if requests.Load() != 1 {
			t.Fatalf("drift probe made %d requests, want 1", requests.Load())
		}
		resetHard(t, root, base)
	})

	t.Run("drifted live catalog forces the release", func(t *testing.T) {
		requests.Store(0)
		liveCatalog.Store(`{"schema_version":1,"packs":["stale"]}` + "\n")
		t.Cleanup(func() { liveCatalog.Store(committedCatalog) })
		selection := pushWithoutPackDiff(t)
		if !selection.PacksRelease || !selection.Packs {
			t.Fatalf("drifted catalog did not select the release: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("unreadable registry forces the release", func(t *testing.T) {
		requests.Store(0)
		liveStatus.Store(http.StatusInternalServerError)
		t.Cleanup(func() { liveStatus.Store(http.StatusOK) })
		selection := pushWithoutPackDiff(t)
		if !selection.PacksRelease || !selection.Packs {
			t.Fatalf("unreadable registry did not select the release: %+v", selection)
		}
		if requests.Load() != 3 {
			t.Fatalf("drift probe made %d requests, want 3 attempts", requests.Load())
		}
		resetHard(t, root, base)
	})

	t.Run("redirects are refused, not followed", func(t *testing.T) {
		requests.Store(0)
		var followed atomic.Int32
		target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			followed.Add(1)
			w.Write([]byte(committedCatalog))
		}))
		t.Cleanup(target.Close)
		redirecting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			http.Redirect(w, r, target.URL, http.StatusFound)
		}))
		t.Cleanup(redirecting.Close)
		publishedCatalogURL = redirecting.URL
		t.Cleanup(func() { publishedCatalogURL = server.URL })
		selection := pushWithoutPackDiff(t)
		if !selection.PacksRelease {
			t.Fatalf("redirecting registry did not select the release: %+v", selection)
		}
		if followed.Load() != 0 {
			t.Fatalf("drift probe followed a redirect %d times", followed.Load())
		}
		resetHard(t, root, base)
	})

	t.Run("pack diff is the fast path without a probe", func(t *testing.T) {
		requests.Store(0)
		writeFixture(t, root, "packs/host-only/actions/status.yaml", "id: host.status\n")
		commitAll(t, root, "pack change")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.PacksRelease {
			t.Fatalf("pack diff did not select the release: %+v", selection)
		}
		if requests.Load() != 0 {
			t.Fatalf("pack diff still probed the registry %d times", requests.Load())
		}
		resetHard(t, root, base)
	})

	t.Run("pull request never probes", func(t *testing.T) {
		requests.Store(0)
		writeFixture(t, root, "docs.md", "docs pr\n")
		commitAll(t, root, "docs pr")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if selection.PacksRelease || requests.Load() != 0 {
			t.Fatalf("pull request probed the registry (%d requests): %+v", requests.Load(), selection)
		}
		resetHard(t, root, base)
	})

	t.Run("repository without the committed catalog never probes", func(t *testing.T) {
		requests.Store(0)
		runGit(t, root, "rm", "-q", catalogPath)
		commitAll(t, root, "drop catalog")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if selection.PacksRelease || requests.Load() != 0 {
			t.Fatalf("catalog-less repository probed the registry (%d requests): %+v", requests.Load(), selection)
		}
		resetHard(t, root, base)
	})
}

func behaviorPlan(service string, versions ...string) string {
	return "services: [" + service + "]\nversions:\n" +
		strings.Join(versions, "") +
		"cases: []\n"
}

func versionRow(version, digestCharacter string, defaultVersion bool) string {
	row := "  - version: \"" + version + "\"\n" +
		"    digest: \"@sha256:" + strings.Repeat(digestCharacter, 64) + "\"\n"
	if defaultVersion {
		row += "    default: true\n"
	}
	return row
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
