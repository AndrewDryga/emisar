package devtool

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

var errComposeProjectNotFound = errors.New("workspace dependency project is not running")

type dependencyComposeProject struct {
	Name        string `json:"Name"`
	Status      string `json:"Status"`
	ConfigFiles string `json:"ConfigFiles"`
}

func selectComposeProject(data []byte, config string) (dependencyComposeProject, error) {
	var projects []dependencyComposeProject
	if err := json.Unmarshal(data, &projects); err != nil {
		return dependencyComposeProject{}, fmt.Errorf("decoding docker compose ls: %w", err)
	}
	config = filepath.Clean(config)
	var matches []dependencyComposeProject
	for _, project := range projects {
		files := strings.Split(project.ConfigFiles, ",")
		if slices.ContainsFunc(files, func(candidate string) bool {
			return filepath.Clean(candidate) == config
		}) {
			matches = append(matches, project)
		}
	}
	if len(matches) == 0 {
		return dependencyComposeProject{}, errComposeProjectNotFound
	}
	if len(matches) != 1 {
		return dependencyComposeProject{}, fmt.Errorf("multiple Compose projects own %s", config)
	}
	return matches[0], nil
}

func (a *App) dependencyProject(ctx context.Context) (dependencyComposeProject, error) {
	if a.inBox() {
		return dependencyComposeProject{}, fmt.Errorf("dependency container diagnostics run on the host")
	}
	data, err := a.output(ctx, a.Root, nil, "docker", "compose", "ls", "--all", "--format", "json")
	if err != nil {
		return dependencyComposeProject{}, err
	}
	return selectComposeProject(data, filepath.Join(a.Root, "dev", "compose.yml"))
}

func addressFromURL(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if parsed.Hostname() == "" || parsed.Port() == "" {
		return "", fmt.Errorf("URL has no host and port: %s", raw)
	}
	return net.JoinHostPort(parsed.Hostname(), parsed.Port()), nil
}

func reachable(address string) bool {
	connection, err := net.DialTimeout("tcp", address, 300*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func boxServiceAddresses() map[int]string {
	addresses := make(map[int]string)
	forwards, err := parseServiceForwards(os.Getenv("COOP_FORWARD"))
	if err != nil {
		return addresses
	}
	for _, forward := range forwards {
		addresses[forward.listenPort] = forward.target
	}
	return addresses
}

func (a *App) status(ctx context.Context) error {
	workspace, err := a.loadWorkspace(ctx)
	if err != nil {
		return err
	}
	environment := "native host"
	if a.inBox() {
		environment = "Coop box"
	}
	fmt.Fprintf(a.Out, "Environment: %s\n", environment)
	a.printURLs(workspace)

	if a.inBox() {
		fmt.Fprintln(a.Out, "Sidecars:  attached Coop network (read-only probe)")
	} else {
		project, projectErr := a.dependencyProject(ctx)
		if errors.Is(projectErr, errComposeProjectNotFound) {
			fmt.Fprintln(a.Out, "Sidecars:  stopped")
		} else if projectErr != nil {
			return projectErr
		} else {
			fmt.Fprintf(a.Out, "Sidecars:  %s (%s)\n", project.Name, project.Status)
		}
	}

	portalAddress, err := addressFromURL(workspace.PortalURL)
	if err != nil {
		return err
	}
	metricsAddress, err := addressFromURL(workspace.MetricsURL)
	if err != nil {
		return err
	}
	databaseAddress, err := addressFromURL(workspace.DatabaseURL)
	if err != nil {
		return err
	}
	keycloakAddress, err := addressFromURL(workspace.KeycloakURL)
	if err != nil {
		return err
	}
	if a.inBox() {
		portalAddress = net.JoinHostPort("127.0.0.1", "4000")
		metricsAddress = net.JoinHostPort("127.0.0.1", "9091")
		forwarded := boxServiceAddresses()
		if address := forwarded[workspace.DBPort]; address != "" {
			databaseAddress = address
		}
		keycloakPort, _ := portFromURL(workspace.KeycloakURL)
		if address := forwarded[keycloakPort]; address != "" {
			keycloakAddress = address
		}
	}
	for _, endpoint := range []struct {
		name    string
		address string
	}{
		{name: "Portal", address: portalAddress},
		{name: "Metrics", address: metricsAddress},
		{name: "Postgres", address: databaseAddress},
		{name: "Keycloak", address: keycloakAddress},
	} {
		state := "down"
		if reachable(endpoint.address) {
			state = "up"
		}
		fmt.Fprintf(a.Out, "[%-4s] %-10s %s\n", state, endpoint.name, endpoint.address)
	}
	return nil
}

func (a *App) logs(ctx context.Context, args []string) error {
	if a.inBox() {
		return fmt.Errorf("run ./run logs on the host")
	}
	follow := false
	var services []string
	for _, argument := range args {
		switch argument {
		case "--follow", "-f":
			if follow {
				return usage("usage: ./run logs [--follow] [db|keycloak]")
			}
			follow = true
		case "db", "keycloak":
			if len(services) != 0 {
				return usage("usage: ./run logs [--follow] [db|keycloak]")
			}
			services = append(services, argument)
		default:
			return usage("usage: ./run logs [--follow] [db|keycloak]")
		}
	}
	project, err := a.dependencyProject(ctx)
	if errors.Is(err, errComposeProjectNotFound) {
		return fmt.Errorf("workspace sidecars are stopped; run ./run up")
	}
	if err != nil {
		return err
	}
	arguments := []string{"compose", "--project-name", project.Name, "-f", filepath.Join(a.Root, "dev", "compose.yml"), "logs", "--no-color", "--timestamps", "--tail", "200"}
	if follow {
		arguments = append(arguments, "--follow")
	}
	arguments = append(arguments, services...)
	return a.run(ctx, a.Root, nil, "docker", arguments...)
}

func (a *App) psql(ctx context.Context, args []string) error {
	workspace, err := a.loadWorkspace(ctx)
	if err != nil {
		return err
	}
	env := a.workspaceEnv(workspace)
	env["PGDATABASE"] = "emisar_dev"
	env["PGUSER"] = "postgres"
	env["PGPASSWORD"] = "postgres"
	return a.run(ctx, a.Root, env, "psql", append([]string{"-X"}, args...)...)
}
