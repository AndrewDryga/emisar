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

// workspaceDependency is one of the services Coop publishes for a workspace.
// Commands name the ones their phases actually reach, because a workspace can
// legitimately hold a subset: Coop hides the Keycloak TLS key, so a box that
// was never granted it has no Keycloak service at all. Demanding every URL up
// front failed database-only routes — the changed-scope Portal gate among them
// — before they ran a single test they could have passed.
type workspaceDependency int

const (
	needPortal workspaceDependency = iota
	needMetrics
	needDatabase
	needKeycloak
)

// everyDependency is the full set, for commands that serve or diagnose the
// whole workspace rather than one slice of it.
var everyDependency = []workspaceDependency{needPortal, needMetrics, needDatabase, needKeycloak}

// One table so a dependency's name, its Coop variable, and the field it lands
// in cannot drift apart. Indexed by workspaceDependency.
var workspaceDependencies = []struct {
	name        string
	boxVariable string
	field       func(*Workspace) *string
}{
	{"Portal", "COOP_SERVE_URL_4000", func(w *Workspace) *string { return &w.PortalURL }},
	{"Metrics", "COOP_SERVE_URL_9091", func(w *Workspace) *string { return &w.MetricsURL }},
	{"Postgres", "COOP_SERVICE_DB_URL", func(w *Workspace) *string { return &w.DatabaseURL }},
	{"Keycloak", "COOP_SERVICE_KEYCLOAK_URL", func(w *Workspace) *string { return &w.KeycloakURL }},
}

func (d workspaceDependency) String() string { return workspaceDependencies[d].name }

func (d workspaceDependency) boxVariable() string { return workspaceDependencies[d].boxVariable }

func (w *Workspace) dependencyURL(d workspaceDependency) *string {
	return workspaceDependencies[d].field(w)
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

// discoverWorkspace reports every URL Coop publishes, without judging which are
// present: which ones matter belongs to the command, not to discovery.
func (a *App) discoverWorkspace(ctx context.Context) (Workspace, error) {
	workspace := Workspace{}
	if a.inBox() {
		for _, dependency := range everyDependency {
			*workspace.dependencyURL(dependency) = os.Getenv(dependency.boxVariable())
		}
		// Loop boxes do not publish host ports. These listeners belong to our
		// own Phoenix process, unlike sidecars whose URLs must come from Coop.
		if workspace.PortalURL == "" {
			workspace.PortalURL = "http://localhost:4000"
		}
		if workspace.MetricsURL == "" {
			workspace.MetricsURL = "http://localhost:9091"
		}
		return workspace, nil
	}
	data, err := a.output(ctx, a.Root, nil, "coop", "fork", "ls", "--json")
	if err != nil {
		return Workspace{}, err
	}
	var list workspaceList
	if err := json.Unmarshal(data, &list); err != nil {
		return Workspace{}, fmt.Errorf("decoding coop fork ls --json: %w", err)
	}
	for _, candidate := range list.Workspaces {
		if candidate.Path != a.Root {
			continue
		}
		workspace.PortalURL = candidate.Serve["4000"]
		workspace.MetricsURL = candidate.Serve["9091"]
		workspace.DatabaseURL = candidate.Services["db:5432"]
		workspace.KeycloakURL = candidate.Services["keycloak:8443"]
		return workspace, nil
	}
	return Workspace{}, fmt.Errorf("coop did not report URLs for workspace %s", a.Root)
}

// loadWorkspace discovers the workspace and then requires exactly the
// dependencies the caller named. A URL it did not ask for may be absent or
// malformed without failing the command.
func (a *App) loadWorkspace(ctx context.Context, needs ...workspaceDependency) (Workspace, error) {
	workspace, err := a.discoverWorkspace(ctx)
	if err != nil {
		return Workspace{}, err
	}
	for _, need := range needs {
		raw := *workspace.dependencyURL(need)
		if raw == "" {
			return Workspace{}, a.missingDependency(need)
		}
		parsed, parseErr := url.Parse(raw)
		if parseErr != nil || parsed.Scheme == "" || parsed.Host == "" {
			return Workspace{}, fmt.Errorf("the %s URL is not an absolute URL: %q", need, raw)
		}
		if need == needDatabase {
			port, portErr := strconv.Atoi(parsed.Port())
			if portErr != nil || port < 1 || port > 65535 {
				return Workspace{}, fmt.Errorf("the Postgres service URL has an invalid port: %s", raw)
			}
			workspace.DBPort = port
		}
	}
	return workspace, nil
}

// missingDependency names the one service that is missing and how to get it,
// rather than reporting that some unnamed URL out of four was not injected.
func (a *App) missingDependency(need workspaceDependency) error {
	if a.inBox() {
		return fmt.Errorf("this command needs %s, and Coop injected no %s into this box; start the service on the host with ./run up and re-enter the box",
			need, need.boxVariable())
	}
	return fmt.Errorf("this command needs %s, and coop reports no %s URL for workspace %s; start the workspace services with ./run up",
		need, need, a.Root)
}

// workspaceEnv exports only what the workspace actually holds. An absent
// service leaves its variable unset instead of exporting a value built around
// an empty URL: "/realms/emisar" is not an issuer, and the seeds would have
// taken it for one.
func (a *App) workspaceEnv(workspace Workspace) map[string]string {
	env := map[string]string{}
	if workspace.DBPort != 0 {
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
		env["DATABASE_URL"] = fmt.Sprintf("ecto://postgres:postgres@%s/emisar_dev", net.JoinHostPort(databaseHost, databasePort))
		env["PGHOST"] = databaseHost
		env["PGPORT"] = databasePort
	}
	if workspace.PortalURL != "" {
		env["EMISAR_DEV_URL"] = workspace.PortalURL
	}
	if workspace.KeycloakURL != "" {
		env["EMISAR_DEV_CA_BUNDLE"] = a.caBundle()
		env["EMISAR_DEV_KEYCLOAK_ISSUER"] = workspace.KeycloakURL + "/realms/emisar"
	}
	return env
}

func (a *App) printURLs(workspace Workspace) {
	fmt.Fprintf(a.Out, "Portal:   %s\nMetrics:  %s\nPostgres: %s\nKeycloak: %s\n",
		workspace.PortalURL, workspace.MetricsURL, workspace.DatabaseURL, workspace.KeycloakURL)
}
