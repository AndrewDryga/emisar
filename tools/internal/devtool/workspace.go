package devtool

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
)

type Workspace struct {
	PortalURL   string
	MetricsURL  string
	DatabaseURL string
	KeycloakURL string
	DBPort      int
}

type workspaceList struct {
	Workspaces []struct {
		Path     string            `json:"path"`
		Serve    map[string]string `json:"serve"`
		Services map[string]string `json:"services"`
	} `json:"workspaces"`
}

func (a *App) inBox() bool {
	return os.Getenv("COOP_BOX") == "1"
}

func (a *App) loadWorkspace(ctx context.Context) (Workspace, error) {
	workspace := Workspace{}
	if a.inBox() {
		workspace.PortalURL = os.Getenv("COOP_SERVE_URL_4000")
		workspace.MetricsURL = os.Getenv("COOP_SERVE_URL_9091")
		workspace.DatabaseURL = os.Getenv("COOP_SERVICE_DB_URL")
		workspace.KeycloakURL = os.Getenv("COOP_SERVICE_KEYCLOAK_URL")
		if workspace.PortalURL == "" || workspace.MetricsURL == "" || workspace.DatabaseURL == "" || workspace.KeycloakURL == "" {
			return Workspace{}, fmt.Errorf("coop did not inject every required workspace URL")
		}
	} else {
		data, err := a.output(ctx, a.Root, nil, "coop", "fork", "ls", "--json")
		if err != nil {
			return Workspace{}, err
		}
		var list workspaceList
		if err := json.Unmarshal(data, &list); err != nil {
			return Workspace{}, fmt.Errorf("decoding coop fork ls --json: %w", err)
		}
		found := false
		for _, candidate := range list.Workspaces {
			if candidate.Path != a.Root {
				continue
			}
			workspace.PortalURL = candidate.Serve["4000"]
			workspace.MetricsURL = candidate.Serve["9091"]
			workspace.DatabaseURL = candidate.Services["db:5432"]
			workspace.KeycloakURL = candidate.Services["keycloak:8443"]
			found = true
			break
		}
		if !found {
			return Workspace{}, fmt.Errorf("coop did not report URLs for workspace %s", a.Root)
		}
	}

	database, err := url.Parse(workspace.DatabaseURL)
	if err != nil {
		return Workspace{}, fmt.Errorf("parsing Postgres service URL: %w", err)
	}
	port, err := strconv.Atoi(database.Port())
	if err != nil || port < 1 || port > 65535 {
		return Workspace{}, fmt.Errorf("the Postgres service URL has an invalid port: %s", workspace.DatabaseURL)
	}
	workspace.DBPort = port
	return workspace, nil
}

func (a *App) workspaceEnv(workspace Workspace) map[string]string {
	databaseHost := "localhost"
	databasePort := strconv.Itoa(workspace.DBPort)
	if a.inBox() {
		if configured := os.Getenv("PGHOST"); configured != "" {
			databaseHost = configured
		}
		if configured := os.Getenv("PGPORT"); configured != "" {
			databasePort = configured
		}
	}
	return map[string]string{
		"DATABASE_URL":               fmt.Sprintf("ecto://postgres:postgres@%s/emisar_dev", net.JoinHostPort(databaseHost, databasePort)),
		"EMISAR_DEV_URL":             workspace.PortalURL,
		"EMISAR_DEV_KEYCLOAK_ISSUER": workspace.KeycloakURL + "/realms/emisar",
		"EMISAR_DEV_CA_BUNDLE":       a.caBundle(),
		"PGHOST":                     databaseHost,
		"PGPORT":                     databasePort,
	}
}

func (a *App) printURLs(workspace Workspace) {
	fmt.Fprintf(a.Out, "Portal:   %s\nMetrics:  %s\nPostgres: %s\nKeycloak: %s\n",
		workspace.PortalURL, workspace.MetricsURL, workspace.DatabaseURL, workspace.KeycloakURL)
}
