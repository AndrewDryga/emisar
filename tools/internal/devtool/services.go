package devtool

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func (a *App) up(ctx context.Context) (Workspace, map[string]string, error) {
	if !a.inBox() {
		if err := a.generateCertificates(false); err != nil {
			return Workspace{}, nil, err
		}
		if a.certsChanged {
			if err := a.run(ctx, a.Root, nil, "coop", "down"); err != nil {
				return Workspace{}, nil, err
			}
		}
		if err := a.run(ctx, a.Root, nil, "coop", "up"); err != nil {
			return Workspace{}, nil, err
		}
	}
	workspace, err := a.loadWorkspace(ctx)
	if err != nil {
		return Workspace{}, nil, err
	}
	env := a.workspaceEnv(workspace)
	if err := a.makeCABundle(ctx); err != nil {
		return Workspace{}, nil, err
	}
	return workspace, env, nil
}

func (a *App) down(ctx context.Context, args []string) error {
	all := len(args) == 1 && args[0] == "--all"
	if !all {
		if err := exact(args, 0, "usage: ./run down [--all]"); err != nil {
			return err
		}
	}
	if a.inBox() {
		return fmt.Errorf("run ./run down on the host")
	}
	if err := a.run(ctx, a.Root, nil, "coop", "down"); err != nil {
		return err
	}
	if !all {
		return nil
	}
	// Volumes stay: down stops stacks, it never destroys development data.
	return a.run(ctx, a.Root, nil, "docker", "compose", "down")
}

func (a *App) tlsClient() (*http.Client, error) {
	ca, err := os.ReadFile(filepath.Join(a.Certs, "ca.crt"))
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, fmt.Errorf("development CA contains no certificate")
	}
	return &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    pool,
		}},
	}, nil
}

func waitUntil(ctx context.Context, attempts int, delay time.Duration, check func() error) error {
	var last error
	for range attempts {
		if last = check(); last == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return last
}

func (a *App) waitForDependencies(ctx context.Context, workspace Workspace) error {
	database, err := url.Parse(workspace.DatabaseURL)
	if err != nil {
		return err
	}
	err = waitUntil(ctx, 60, time.Second, func() error {
		connection, dialErr := net.DialTimeout("tcp", database.Host, time.Second)
		if dialErr != nil {
			return dialErr
		}
		return connection.Close()
	})
	if err != nil {
		return fmt.Errorf("waiting for Postgres at %s: %w", workspace.DatabaseURL, err)
	}

	client, err := a.tlsClient()
	if err != nil {
		return err
	}
	endpoint := workspace.KeycloakURL + "/realms/master/.well-known/openid-configuration"
	err = waitUntil(ctx, 90, time.Second, func() error {
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if requestErr != nil {
			return requestErr
		}
		response, requestErr := client.Do(request)
		if requestErr != nil {
			return requestErr
		}
		defer response.Body.Close()
		if response.StatusCode/100 != 2 {
			return fmt.Errorf("HTTP %s", response.Status)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("waiting for Keycloak at %s: %w", workspace.KeycloakURL, err)
	}
	return nil
}

func doJSON(ctx context.Context, client *http.Client, method, endpoint, token string, body any, target any) error {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		payload = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint, payload)
	if err != nil {
		return err
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("%s %s: HTTP %s: %s", method, endpoint, response.Status, strings.TrimSpace(string(message)))
	}
	if target != nil {
		if err := json.NewDecoder(response.Body).Decode(target); err != nil {
			return fmt.Errorf("decoding %s: %w", endpoint, err)
		}
	}
	return nil
}

func (a *App) configureKeycloak(ctx context.Context, workspace Workspace) error {
	if err := a.waitForDependencies(ctx, workspace); err != nil {
		return err
	}
	client, err := a.tlsClient()
	if err != nil {
		return err
	}
	form := url.Values{
		"client_id":  {"admin-cli"},
		"username":   {"admin"},
		"password":   {"admin"},
		"grant_type": {"password"},
	}
	var token struct {
		AccessToken string `json:"access_token"`
	}
	tokenURL := workspace.KeycloakURL + "/realms/master/protocol/openid-connect/token"
	err = waitUntil(ctx, 30, time.Second, func() error {
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
		if requestErr != nil {
			return requestErr
		}
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		response, requestErr := client.Do(request)
		if requestErr != nil {
			return requestErr
		}
		defer response.Body.Close()
		if response.StatusCode/100 != 2 {
			return fmt.Errorf("HTTP %s", response.Status)
		}
		return json.NewDecoder(response.Body).Decode(&token)
	})
	if err != nil || token.AccessToken == "" {
		return fmt.Errorf("could not obtain the Keycloak dev admin token: %w", err)
	}

	var clients []map[string]any
	endpoint := workspace.KeycloakURL + "/admin/realms/emisar/clients?clientId=emisar-portal"
	if err := doJSON(ctx, client, http.MethodGet, endpoint, token.AccessToken, nil, &clients); err != nil {
		return err
	}
	if len(clients) != 1 {
		return fmt.Errorf("emisar-portal client missing or duplicated")
	}
	configuration := clients[0]
	id, ok := configuration["id"].(string)
	if !ok || id == "" {
		return fmt.Errorf("emisar-portal client has no id")
	}
	configuration["redirectUris"] = []string{workspace.PortalURL + "/sign_in/sso/callback"}
	configuration["webOrigins"] = []string{workspace.PortalURL}
	attributes, _ := configuration["attributes"].(map[string]any)
	if attributes == nil {
		attributes = make(map[string]any)
	}
	attributes["post.logout.redirect.uris"] = workspace.PortalURL + "/*"
	configuration["attributes"] = attributes
	return doJSON(ctx, client, http.MethodPut, workspace.KeycloakURL+"/admin/realms/emisar/clients/"+url.PathEscape(id), token.AccessToken, configuration, nil)
}

func (a *App) prepareDatabase(ctx context.Context, env map[string]string) error {
	if err := a.run(ctx, a.Portal, env, "mix", "ecto.create"); err != nil {
		return err
	}
	return a.run(ctx, a.Portal, env, "mix", "ecto.migrate")
}

func (a *App) setup(ctx context.Context) error {
	if _, err := exec.LookPath("mix"); err != nil {
		return fmt.Errorf("missing mix")
	}
	if !a.inBox() {
		if err := a.run(ctx, a.Root, nil, "coop", "build"); err != nil {
			return err
		}
	}
	workspace, env, err := a.up(ctx)
	if err != nil {
		return err
	}
	if err := a.waitForDependencies(ctx, workspace); err != nil {
		return err
	}
	if err := a.run(ctx, a.Portal, env, "mix", "deps.get"); err != nil {
		return err
	}
	if err := a.prepareDatabase(ctx, env); err != nil {
		return err
	}
	if err := a.ensureBrowser(); err != nil {
		return err
	}
	if err := a.ensureImageTools(); err != nil {
		return err
	}
	if err := a.configureKeycloak(ctx, workspace); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "development setup ready; run './run seed' once when demo data is needed")
	a.printURLs(workspace)
	return nil
}

func (a *App) seed(ctx context.Context) error {
	workspace, env, err := a.up(ctx)
	if err != nil {
		return err
	}
	if err := a.configureKeycloak(ctx, workspace); err != nil {
		return err
	}
	if err := a.prepareDatabase(ctx, env); err != nil {
		return err
	}
	env["EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET"] = oidcSecret
	env["EMISAR_DEV_KEYCLOAK_PROVIDER_ID"] = "11111111-1111-7111-8111-111111111111"
	env["EMISAR_DEV_FIXED_SCIM_TOKEN"] = scimToken
	return a.run(ctx, a.Portal, env, "mix", "run", "--no-start", "-e", `Logger.configure(level: :info); {:ok, _} = Application.ensure_all_started(:emisar); Code.eval_file("apps/emisar/priv/repo/seeds.exs")`)
}

func (a *App) reset(ctx context.Context, args []string) error {
	seedAfter, yes := false, false
	for _, argument := range args {
		switch argument {
		case "--seed":
			seedAfter = true
		case "--yes":
			yes = true
		default:
			return usage("usage: ./run reset [--seed] [--yes]")
		}
	}
	if !yes {
		fmt.Fprint(a.Out, "Drop this workspace's emisar_dev database? [y/N] ")
		var answer string
		if _, err := fmt.Fscanln(a.In, &answer); err != nil || (answer != "y" && answer != "Y") {
			return fmt.Errorf("database reset cancelled")
		}
	}
	workspace, env, err := a.up(ctx)
	if err != nil {
		return err
	}
	for _, arguments := range [][]string{{"ecto.drop"}, {"ecto.create"}, {"ecto.migrate"}} {
		if err := a.run(ctx, a.Portal, env, "mix", arguments...); err != nil {
			return err
		}
	}
	if err := a.configureKeycloak(ctx, workspace); err != nil {
		return err
	}
	if seedAfter {
		return a.seed(ctx)
	}
	return nil
}

func (a *App) doctor(ctx context.Context) error {
	for _, tool := range []string{"git", "mix"} {
		if _, err := exec.LookPath(tool); err != nil {
			return fmt.Errorf("missing %s", tool)
		}
	}
	if !a.inBox() {
		for _, tool := range []string{"coop", "docker"} {
			if _, err := exec.LookPath(tool); err != nil {
				return fmt.Errorf("missing %s", tool)
			}
		}
	}
	workspace, _, err := a.up(ctx)
	if err != nil {
		return err
	}
	if err := a.configureKeycloak(ctx, workspace); err != nil {
		return err
	}
	if err := a.ensureBrowser(); err != nil {
		return err
	}
	if err := a.ensureImageTools(); err != nil {
		return err
	}
	ca, _, err := loadCA(a.Certs)
	if err != nil {
		return err
	}
	if !validLeaf(a.Certs, ca, time.Now()) {
		return fmt.Errorf("the Keycloak development certificate is invalid")
	}
	client, err := a.tlsClient()
	if err != nil {
		return err
	}
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, workspace.KeycloakURL+"/realms/emisar/.well-known/openid-configuration", nil)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	var discovery struct {
		Issuer string `json:"issuer"`
	}
	if err := json.NewDecoder(response.Body).Decode(&discovery); err != nil {
		return err
	}
	expected := workspace.KeycloakURL + "/realms/emisar"
	if discovery.Issuer != expected {
		return fmt.Errorf("OIDC issuer is %q, expected %q", discovery.Issuer, expected)
	}
	if err := a.run(ctx, a.Root, nil, "git", "check-ignore", "-q", "dev/keycloak/certs/generated/tls.key"); err != nil {
		return fmt.Errorf("generated Keycloak private keys are not ignored")
	}
	if !a.inBox() && runtime.GOOS == "darwin" {
		if err := a.certificateStatus(ctx); err != nil {
			return fmt.Errorf("the Keycloak TLS chain is valid, but the host browser does not trust its CA: %w", err)
		}
	}
	fmt.Fprintln(a.Out, "tools, services, TLS, exact OIDC issuer, and key isolation are healthy")
	a.printURLs(workspace)
	return nil
}

func (a *App) smoke(ctx context.Context) error {
	if err := a.generateCertificates(false); err != nil {
		return err
	}
	if a.certsChanged {
		if err := a.run(ctx, a.Root, nil, "docker", "compose", "down"); err != nil {
			return err
		}
	}
	if err := a.run(ctx, a.Root, nil, "docker", "compose", "up", "-d", "--build"); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "packaged stack started at http://localhost:4010")
	return nil
}
