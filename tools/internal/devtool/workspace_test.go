package devtool

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDatabaseOnlyNativeCommandReusesRunningDatabase(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "")
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	workspaceJSON, err := json.Marshal(map[string]any{"workspaces": []any{map[string]any{
		"path": app.Root,
		"services": map[string]string{
			"db:5432":       "postgresql://" + listener.Addr().String(),
			"keycloak:8443": "https://localhost:1",
		},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	// No sidecar startup is allowed: Keycloak's TLS mount may be withheld,
	// and a database-only command has no reason to restart that stack.
	script := fmt.Sprintf("#!/bin/sh\n[ \"$*\" = 'fork ls --json' ] || exit 99\nprintf '%%s\\n' '%s'\n", workspaceJSON)
	if err := os.WriteFile(filepath.Join(bin, "coop"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	env, err := app.upForDatabase(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if env["PGPORT"] == "" || env["DATABASE_URL"] == "" {
		t.Fatalf("missing database environment: %v", env)
	}
	if _, err := os.Stat(app.Certs); !os.IsNotExist(err) {
		t.Fatalf("database-only command touched TLS state: %v", err)
	}
}

// boxWorkspace injects exactly the Coop variables a case declares, so an
// unnamed dependency is genuinely absent rather than left over from the box
// this test happens to run in.
func boxWorkspace(t *testing.T, urls map[workspaceDependency]string) *App {
	t.Helper()
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	t.Setenv("PGHOST", "")
	t.Setenv("PGPORT", "")
	for _, dependency := range everyDependency {
		t.Setenv(dependency.boxVariable(), urls[dependency])
	}
	return app
}

func TestLoadWorkspaceRequiresOnlyTheNamedDependencies(t *testing.T) {
	databaseOnly := map[workspaceDependency]string{
		needDatabase: "postgres://postgres:postgres@db:5432/emisar_dev",
	}
	everyURL := map[workspaceDependency]string{
		needPortal:   "http://localhost:43659",
		needMetrics:  "http://localhost:28617",
		needDatabase: "postgres://postgres:postgres@db:5432/emisar_dev",
		needKeycloak: "https://localhost:30344",
	}
	for _, testCase := range []struct {
		name string
		urls map[workspaceDependency]string
		// The dependency set a command declares.
		needs []workspaceDependency
		// A substring of the refusal, or "" when the load must succeed.
		wantError string
	}{
		{
			// The route the whole change exists for: a box whose Keycloak never
			// started because Coop hid its TLS key still runs the Portal tests.
			name:  "database-only needs pass without portal, metrics, or Keycloak",
			urls:  databaseOnly,
			needs: []workspaceDependency{needDatabase},
		},
		{
			name:      "a command that serves the whole workspace still refuses",
			urls:      databaseOnly,
			needs:     everyDependency,
			wantError: "this command needs Keycloak",
		},
		{
			name:      "the refusal names the missing service and its Coop variable",
			urls:      databaseOnly,
			needs:     []workspaceDependency{needKeycloak},
			wantError: "this command needs Keycloak, and Coop injected no COOP_SERVICE_KEYCLOAK_URL",
		},
		{
			name:  "a complete workspace satisfies every dependency",
			urls:  everyURL,
			needs: everyDependency,
		},
		{
			name:  "a command that needs nothing loads an empty workspace",
			urls:  nil,
			needs: nil,
		},
		{
			name:      "a database URL without a scheme or host is refused",
			urls:      map[workspaceDependency]string{needDatabase: "db:5432/emisar_dev"},
			needs:     []workspaceDependency{needDatabase},
			wantError: "the Postgres URL is not an absolute URL",
		},
		{
			name:      "a portal URL without a scheme is refused",
			urls:      map[workspaceDependency]string{needPortal: "localhost:43659"},
			needs:     []workspaceDependency{needPortal},
			wantError: "the Portal URL is not an absolute URL",
		},
		{
			name:      "a database URL with no port is refused",
			urls:      map[workspaceDependency]string{needDatabase: "postgres://db/emisar_dev"},
			needs:     []workspaceDependency{needDatabase},
			wantError: "the Postgres service URL has an invalid port",
		},
		{
			name:      "a database URL with an out-of-range port is refused",
			urls:      map[workspaceDependency]string{needDatabase: "postgres://db:99999/emisar_dev"},
			needs:     []workspaceDependency{needDatabase},
			wantError: "the Postgres service URL has an invalid port",
		},
		{
			// A malformed URL nobody asked for is not this command's problem.
			name:  "a malformed URL outside the declared set is ignored",
			urls:  map[workspaceDependency]string{needDatabase: everyURL[needDatabase], needKeycloak: "not a url at all"},
			needs: []workspaceDependency{needDatabase},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			app := boxWorkspace(t, testCase.urls)
			workspace, err := app.loadWorkspace(context.Background(), testCase.needs...)
			if testCase.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), testCase.wantError) {
					t.Fatalf("loadWorkspace error = %v, want one containing %q", err, testCase.wantError)
				}
				return
			}
			if err != nil {
				t.Fatalf("loadWorkspace = %v", err)
			}
			if testCase.urls[needDatabase] != "" && workspace.DBPort != 5432 {
				t.Fatalf("database port = %d, want 5432", workspace.DBPort)
			}
		})
	}
}

func TestUnpublishedBoxUsesOwnedLocalListeners(t *testing.T) {
	app := boxWorkspace(t, nil)
	workspace, err := app.loadWorkspace(t.Context(), needPortal, needMetrics)
	if err != nil {
		t.Fatal(err)
	}
	if workspace.PortalURL != "http://localhost:4000" || workspace.MetricsURL != "http://localhost:9091" {
		t.Fatalf("local listeners = %+v", workspace)
	}
	if workspace.DatabaseURL != "" || workspace.KeycloakURL != "" {
		t.Fatalf("invented sidecar URL: %+v", workspace)
	}
	t.Setenv("COOP_SERVE_URL_4000", "http://localhost:43659")
	t.Setenv("COOP_SERVE_URL_9091", "http://localhost:28617")
	workspace, err = app.loadWorkspace(t.Context(), needPortal, needMetrics)
	if err != nil || workspace.PortalURL != "http://localhost:43659" || workspace.MetricsURL != "http://localhost:28617" {
		t.Fatalf("supplied listeners not preserved: %+v, %v", workspace, err)
	}
}

func TestURLsReportsAnUnpublishedBoxWithoutRequiringSidecars(t *testing.T) {
	app := boxWorkspace(t, nil)
	if err := app.Run(t.Context(), []string{"urls"}); err != nil {
		t.Fatal(err)
	}
	out := app.Out.(*bytes.Buffer).String()
	if !strings.Contains(out, "Portal:   http://localhost:4000") || !strings.Contains(out, "Metrics:  http://localhost:9091") {
		t.Fatalf("local URLs not reported: %q", out)
	}
}

func TestLoadWorkspaceNamesTheMissingServiceOnTheHost(t *testing.T) {
	app := testApp(t)
	if _, err := app.loadWorkspace(context.Background(), needDatabase); err == nil ||
		!strings.Contains(err.Error(), "coop") {
		// testApp has no coop binary on its temporary root, so discovery — not
		// validation — is what fails here. The point is that a host miss still
		// reports coop, never a fabricated URL.
		t.Fatalf("host loadWorkspace error = %v", err)
	}
}

func TestWorkspaceEnvOmitsServicesTheWorkspaceDoesNotHave(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	t.Setenv("PGHOST", "db")
	t.Setenv("PGPORT", "5432")
	env := app.workspaceEnv(Workspace{DatabaseURL: "postgres://db:5432/emisar_dev", DBPort: 5432})
	if env["DATABASE_URL"] != "ecto://postgres:postgres@db:5432/emisar_dev" {
		t.Fatalf("database environment = %#v", env)
	}
	// An empty Keycloak URL must not become the issuer "/realms/emisar": the
	// seeds read this variable and would have registered that as a provider.
	if issuer, ok := env["EMISAR_DEV_KEYCLOAK_ISSUER"]; ok {
		t.Fatalf("issuer exported without a Keycloak service: %q", issuer)
	}
	if bundle, ok := env["EMISAR_DEV_CA_BUNDLE"]; ok {
		t.Fatalf("CA bundle exported without a Keycloak service: %q", bundle)
	}
	if portal, ok := env["EMISAR_DEV_URL"]; ok {
		t.Fatalf("portal URL exported without a Portal service: %q", portal)
	}
}

func TestWorkspaceEnvOmitsTheDatabaseWithoutOne(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	t.Setenv("PGHOST", "db")
	t.Setenv("PGPORT", "5432")
	env := app.workspaceEnv(Workspace{PortalURL: "http://localhost:43659"})
	for _, key := range []string{"DATABASE_URL", "PGHOST", "PGPORT"} {
		if value, ok := env[key]; ok {
			t.Fatalf("%s exported without a database: %q", key, value)
		}
	}
	if env["EMISAR_DEV_URL"] != "http://localhost:43659" {
		t.Fatalf("portal environment = %#v", env)
	}
}
