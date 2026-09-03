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

	t.Run("workflow pull request validates without pack behavior or release", func(t *testing.T) {
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
		if len(selection.PackBehavior) != 0 || !selection.SigningE2E || !selection.SSOE2E {
			t.Fatalf("workflow selection included pack behavior or omitted integration gates: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("pack CI workflow validates every behavior plan", func(t *testing.T) {
		writeFixture(t, root, ".github/workflows/ci.yml", "name: CI\n")
		commitAll(t, root, "pack CI workflow")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 3 {
			t.Fatalf("pack CI workflow selection = %v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("release-authority composite selects tools and workflows", func(t *testing.T) {
		writeFixture(t, root, ".github/actions/verify-release-tag/action.yml", "name: verify\n")
		commitAll(t, root, "composite edit")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Tools || !selection.Workflows {
			t.Fatalf("composite-only change validated nothing: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("tracked dist integration file selects tools", func(t *testing.T) {
		writeFixture(t, root, "dist/cursor-plugin/mcp.json", "{}\n")
		commitAll(t, root, "dist edit")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Tools {
			t.Fatalf("dist change did not select tools: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("a runner pipeline package selects pack behavior", func(t *testing.T) {
		writeFixture(t, root, "runner/internal/redact/rules.go", "package redact\n")
		commitAll(t, root, "redact edit")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 3 {
			t.Fatalf("redact change did not select pack behavior: %+v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("an SSO controller selects the SSO e2e", func(t *testing.T) {
		writeFixture(t, root, "portal/apps/emisar_web/lib/emisar_web/controllers/sso_controller.ex", "defmodule X do\nend\n")
		commitAll(t, root, "sso controller")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.SSOE2E {
			t.Fatalf("SSO controller change did not select the SSO e2e: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("the e2e stack compose selects tools", func(t *testing.T) {
		writeFixture(t, root, "docker-compose.yml", "services: {}\n")
		commitAll(t, root, "compose edit")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Tools {
			t.Fatalf("compose change did not select tools: %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("unrelated workflow does not select pack behavior", func(t *testing.T) {
		writeFixture(t, root, ".github/workflows/mcp-eval.yml", "name: MCP eval\n")
		commitAll(t, root, "MCP eval workflow")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if len(selection.PackBehavior) != 0 {
			t.Fatalf("unrelated workflow selection = %v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("CI selector changes validate every gate without release", func(t *testing.T) {
		for _, file := range []string{"tools/internal/ci/select.go", "tools/cmd/ci/main.go"} {
			writeFixture(t, root, file, "package ci\n")
			commitAll(t, root, "CI selector")
			selection, err := Select(context.Background(), root, "pull_request", base)
			if err != nil {
				t.Fatal(err)
			}
			if !selection.Workflows || !selection.Portal || !selection.Runner || !selection.MCP || !selection.Tools || !selection.Packs || !selection.Infra || !selection.Deps || !selection.MCPListing || !selection.RunnerImage {
				t.Fatalf("%s selection is incomplete: %+v", file, selection)
			}
			if selection.PortalRelease || selection.PacksRelease {
				t.Fatalf("%s selected release for a pull request: %+v", file, selection)
			}
			if len(selection.PackBehavior) != 3 || !selection.SigningE2E || !selection.SSOE2E {
				t.Fatalf("%s omitted integration gates: %+v", file, selection)
			}
			resetHard(t, root, base)
		}
	})

	t.Run("Go checkout attributes select every Go gate", func(t *testing.T) {
		writeFixture(t, root, ".gitattributes", "*.go text eol=lf\n")
		commitAll(t, root, "Go checkout contract")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if got := selection.GoModules(); strings.Join(got, ",") != "runner,mcp,tools" {
			t.Fatalf("GoModules() = %q, want every Go module", got)
		}
		if selection.Portal || selection.PortalRelease || selection.PacksRelease {
			t.Fatalf("Go checkout attributes selected an unrelated release: %+v", selection)
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

	t.Run("pack test plan validates only that pack without release", func(t *testing.T) {
		writeFixture(t, root, "packs/postgres/test/cases.yaml", behaviorPlan("postgres",
			versionRow("18.4", "c", true),
			versionRow("17.6", "b", false),
		))
		commitAll(t, root, "postgres behavior plan")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Packs || selection.Portal || selection.PortalRelease || selection.PacksRelease {
			t.Fatalf("pack test plan selected runtime publication inputs: %+v", selection)
		}
		if len(selection.PackBehavior) != 2 ||
			selection.PackBehavior[0].Pack != "postgres" ||
			selection.PackBehavior[1].Pack != "postgres" {
			t.Fatalf("pack test plan selection = %v", selection.PackBehavior)
		}
		resetHard(t, root, base)
	})

	t.Run("pack runtime source still selects publication", func(t *testing.T) {
		writeFixture(t, root, "packs/postgres/actions/uptime.yaml", "id: postgres.uptime\n")
		commitAll(t, root, "postgres runtime source")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Portal || !selection.PortalRelease || !selection.Packs || !selection.PacksRelease {
			t.Fatalf("pack runtime source omitted publication inputs: %+v", selection)
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

	t.Run("pack without plan remains contract only", func(t *testing.T) {
		writeFixture(t, root, "packs/host-only/actions/status.yaml", "id: host.status\nrisk: medium\n")
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

	t.Run("host access harness selects packs validation", func(t *testing.T) {
		for _, file := range []string{
			"dev/test-host-access/Dockerfile.debian",
			"tools/internal/hostaccess/hostaccess.go",
		} {
			writeFixture(t, root, file, "changed\n")
			commitAll(t, root, "host access harness")
			selection, err := Select(context.Background(), root, "pull_request", base)
			if err != nil {
				t.Fatal(err)
			}
			if !selection.Packs || !selection.Tools {
				t.Fatalf("%s selection = %+v", file, selection)
			}
			resetHard(t, root, base)
		}
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

	t.Run("the shared demo seed selects both e2e scenarios", func(t *testing.T) {
		writeFixture(t, root, "portal/apps/emisar/priv/repo/seeds.exs", "# shared seed\n")
		commitAll(t, root, "shared seed")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.SigningE2E || !selection.SSOE2E {
			t.Fatalf("shared seed selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	// Go writes the pack/catalog schema and the Portal reads it; the Portal-side
	// proof lives in the Portal suite, so a Go-only schema change has to select it.
	t.Run("cross-language pack schema selects the portal suite", func(t *testing.T) {
		for _, file := range []string{
			"runner/pkg/packspec/pack.go",
			"runner/pkg/actionspec/action.go",
			"runner/internal/catalog/catalog.go",
		} {
			writeFixture(t, root, file, "package spec\n")
			commitAll(t, root, "pack schema")
			selection, err := Select(context.Background(), root, "pull_request", base)
			if err != nil {
				t.Fatal(err)
			}
			if !selection.Portal || !selection.Packs {
				t.Fatalf("%s selection = %+v", file, selection)
			}
			resetHard(t, root, base)
		}
	})

	// The corpus IS the parity check between the two hostile-JSON validators, so
	// changing it has to run both suites.
	t.Run("the shared JSON corpus selects both Go clients", func(t *testing.T) {
		writeFixture(t, root, "dev/json-corpus/cases.json", "{}\n")
		commitAll(t, root, "json corpus")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Runner || !selection.MCP {
			t.Fatalf("corpus selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("installer harness selects affected Go clients", func(t *testing.T) {
		for _, test := range []struct {
			name       string
			file       string
			wantRunner bool
			wantMCP    bool
		}{
			{name: "runner", file: "tools/internal/installtest/runner.go", wantRunner: true},
			{name: "mcp", file: "tools/internal/installtest/mcp.go", wantMCP: true},
			{name: "mcp windows", file: "tools/internal/installtest/mcp_windows.go", wantMCP: true},
			{name: "shared harness", file: "tools/internal/installtest/harness.go", wantRunner: true, wantMCP: true},
			{name: "command", file: "tools/cmd/installtest/main.go", wantRunner: true, wantMCP: true},
		} {
			t.Run(test.name, func(t *testing.T) {
				writeFixture(t, root, test.file, "package fixture\n")
				commitAll(t, root, "installer harness")
				selection, err := Select(context.Background(), root, "pull_request", base)
				if err != nil {
					t.Fatal(err)
				}
				if selection.Runner != test.wantRunner || selection.MCP != test.wantMCP {
					t.Fatalf("%s selection = %+v", test.file, selection)
				}
				resetHard(t, root, base)
			})
		}
	})

	// The signing lane is the complete bridge-to-Portal-to-runner contract. Each
	// exact seam has regressed independently, so keep the topology explicit.
	t.Run("signing seams select the signing scenario", func(t *testing.T) {
		for _, file := range []string{
			"mcp/sign.go",
			"mcp/main.go",
			"mcp/internal/attest/attest.go",
			"runner/internal/signing/signing.go",
			"runner/internal/attest/attest.go",
			"portal/apps/emisar/lib/emisar/runs.ex",
			"portal/apps/emisar/lib/emisar/runs/attestation.ex",
			"portal/apps/emisar_web/lib/emisar_web/controllers/mcp/action_tools.ex",
		} {
			writeFixture(t, root, file, "package main\n")
			commitAll(t, root, "signing seam")
			selection, err := Select(context.Background(), root, "pull_request", base)
			if err != nil {
				t.Fatal(err)
			}
			if !selection.SigningE2E {
				t.Fatalf("%s did not select signing-e2e: %+v", file, selection)
			}
			resetHard(t, root, base)
		}
	})

	t.Run("primary SSO context selects the SSO scenario", func(t *testing.T) {
		file := "portal/apps/emisar/lib/emisar/sso.ex"
		writeFixture(t, root, file, "defmodule Emisar.SSO do\nend\n")
		commitAll(t, root, "SSO context")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.SSOE2E {
			t.Fatalf("%s did not select sso-e2e: %+v", file, selection)
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

	t.Run("pack registry IAM contract selects infra and pack validation", func(t *testing.T) {
		writeFixture(t, root, "infra/pack_registry_mutable_pointers.json", "[]\n")
		commitAll(t, root, "pack registry contract")
		selection, err := Select(context.Background(), root, "pull_request", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Infra || !selection.Packs || selection.PacksRelease {
			t.Fatalf("pack registry IAM contract selection = %+v", selection)
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

	t.Run("PowerShell MCP installer selects portal and MCP", func(t *testing.T) {
		writeFixture(t, root, "install-mcp.ps1", "param()\n")
		commitAll(t, root, "Windows MCP installer")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if !selection.Portal || !selection.PortalRelease || !selection.MCP || selection.Infra {
			t.Fatalf("PowerShell installer selection = %+v", selection)
		}
		resetHard(t, root, base)
	})

	t.Run("PowerShell MCP installer exports the native Windows gate", func(t *testing.T) {
		writeFixture(t, root, "install-mcp.ps1", "param()\n")
		commitAll(t, root, "Windows MCP installer")
		output := filepath.Join(t.TempDir(), "output")
		summary := filepath.Join(t.TempDir(), "summary")
		if err := WriteSelection(context.Background(), root, "pull_request", base, output, summary); err != nil {
			t.Fatal(err)
		}
		if data, err := os.ReadFile(output); err != nil || !strings.Contains(string(data), "mcp=true\n") {
			t.Fatalf("selection output = %q, %v", data, err)
		}
		if data, err := os.ReadFile(summary); err != nil || !strings.Contains(string(data), "MCP - Windows | run") {
			t.Fatalf("selection summary = %q, %v", data, err)
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

	t.Run("pack test plan does not publish a matching catalog", func(t *testing.T) {
		requests.Store(0)
		writeFixture(t, root, "packs/postgres/test/cases.yaml", behaviorPlan("postgres",
			versionRow("18.4", "b", true),
		))
		commitAll(t, root, "pack behavior plan")
		selection, err := Select(context.Background(), root, "push", base)
		if err != nil {
			t.Fatal(err)
		}
		if selection.PacksRelease || !selection.Packs || len(selection.PackBehavior) != 1 {
			t.Fatalf("pack test plan selected publication or skipped validation: %+v", selection)
		}
		if requests.Load() != 1 {
			t.Fatalf("pack test plan made %d drift probes, want 1", requests.Load())
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
