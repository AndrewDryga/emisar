package devtool

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	devbrowser "github.com/andrewdryga/emisar/tools/internal/browser"
	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

func (a *App) e2eSSO(ctx context.Context) error {
	if err := a.generateCertificates(false); err != nil {
		return err
	}
	portalPort, err := availableTCPPort()
	if err != nil {
		return err
	}
	keycloakPort, err := availableTCPPort()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(a.cacheRoot(), 0o700); err != nil {
		return err
	}
	realm, err := os.CreateTemp(a.cacheRoot(), "sso-realm-*.json")
	if err != nil {
		return err
	}
	realmPath := realm.Name()
	if err := realm.Close(); err != nil {
		return err
	}
	defer os.Remove(realmPath)
	if err := writeSSORealm(
		filepath.Join(a.Root, "dev", "keycloak", "realm.json"),
		realmPath,
		portalPort,
	); err != nil {
		return err
	}
	// CreateTemp makes this 0600 owned by the invoking user, but it is bind
	// mounted into Keycloak, which runs as a non-root user — on Linux that is
	// an unreadable import file and the container exits during startup. It is
	// generated non-secret realm config, so make it world-readable.
	if err := os.Chmod(realmPath, 0o644); err != nil {
		return err
	}

	env := map[string]string{
		"COMPOSE_PROJECT_NAME":  fmt.Sprintf("%s-sso-%d", composeProject(a.Root), portalPort),
		"PORTAL_PORT":           strconv.Itoa(portalPort),
		"KEYCLOAK_PORT":         strconv.Itoa(keycloakPort),
		"KEYCLOAK_PUBLISH_PORT": strconv.Itoa(keycloakPort),
		"KEYCLOAK_REALM_FILE":   realmPath,
	}
	compose := func(commandContext context.Context, args ...string) error {
		return a.run(commandContext, a.Root, env, "docker", append([]string{"compose"}, args...)...)
	}
	defer func() { _ = compose(context.Background(), "down", "-v", "--remove-orphans") }()
	fmt.Fprintln(a.Out, "[sso-e2e] building current portal image (cached if unchanged)...")
	if err := compose(ctx, "build", "portal"); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "[sso-e2e] starting isolated Portal and Keycloak...")
	if err := compose(ctx, "up", "-d", "--wait", "--wait-timeout", "120", "portal", "keycloak"); err != nil {
		// `--wait` reports only that a container never became healthy, so a
		// service that exits during startup takes its reason to the grave and
		// CI shows an unexplained exit status. Dump the same evidence the pack
		// harness does before the deferred teardown removes the containers.
		a.capturePackTestEvidence(ctx, []string{"compose"}, env, []string{"portal", "keycloak", "db"})
		return err
	}
	if err := compose(ctx, "run", "--rm", "seeder"); err != nil {
		return err
	}
	env["PORTAL_URL"] = fmt.Sprintf("http://localhost:%d", portalPort)
	env["KEYCLOAK_ISSUER"] = fmt.Sprintf("https://localhost:%d/realms/emisar", keycloakPort)
	env["KEYCLOAK_CA"] = a.Certs + "/ca.crt"
	env["PROVIDER_ID"] = "11111111-1111-7111-8111-111111111111"
	env["SCIM_TOKEN"] = scimToken
	env["KC_USER"] = "alice"
	env["KC_PASS"] = "Sleep-tight-1234"
	env["ALICE_KC_ID"] = "a11ce000-0000-4000-8000-000000000001"
	// SCIM and OIDC show an IdP's view. Role recomputes, membership flags and
	// session revocation are domain state no protocol surface exposes, so the
	// harness reaches them the way an operator would on a box: an RPC into the
	// running release.
	env["PORTAL_RPC"] = strings.Join([]string{
		"docker", "compose", "exec", "-T", "portal", "bin/emisar", "rpc",
	}, " ")
	if err := a.run(ctx, a.Root, env, "go", "run", "./tools/cmd/sso-e2e"); err != nil {
		// A scenario failure needs the portal's own log as much as a startup failure
		// does — the harness only sees the browser's last URL, which says a redirect
		// did not happen but never why. The deferred teardown removes the containers
		// moments later, so capture it here or lose it.
		a.capturePackTestEvidence(ctx, []string{"compose"}, env, []string{"portal", "keycloak"})
		return err
	}
	return nil
}

func availableTCPPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func writeSSORealm(source, destination string, portalPort int) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	var realm map[string]any
	if err := json.Unmarshal(data, &realm); err != nil {
		return fmt.Errorf("parse Keycloak realm: %w", err)
	}
	clients, ok := realm["clients"].([]any)
	if !ok {
		return fmt.Errorf("the Keycloak realm has no clients")
	}
	updated := false
	for _, raw := range clients {
		client, ok := raw.(map[string]any)
		if !ok || client["clientId"] != "emisar-portal" {
			continue
		}
		client["redirectUris"] = []any{
			fmt.Sprintf("http://localhost:%d/sign_in/sso/callback", portalPort),
		}
		updated = true
		break
	}
	if !updated {
		return fmt.Errorf("the Keycloak realm has no emisar-portal client")
	}
	data, err = json.MarshalIndent(realm, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(destination, data, 0o600)
}

func (a *App) e2eSigning(ctx context.Context) error {
	if err := a.generateCertificates(false); err != nil {
		return err
	}
	env := map[string]string{
		"COMPOSE_PROJECT_NAME":  composeProject(a.Root),
		"PORTAL_PORT":           "0",
		"KEYCLOAK_PUBLISH_PORT": "0",
	}
	compose := func(commandContext context.Context, args ...string) error {
		return a.run(commandContext, a.Root, env, "docker", append([]string{"compose", "--profile", "test"}, args...)...)
	}
	_ = compose(ctx, "down", "-v", "--remove-orphans")
	defer func() { _ = compose(context.Background(), "down", "-v", "--remove-orphans") }()
	fmt.Fprintln(a.Out, "[automation-e2e] building current portal + runner + mcp images (cached if unchanged)...")
	if err := compose(ctx, "build", "portal", "runner-signed", "mcp"); err != nil {
		return err
	}
	fmt.Fprintln(a.Out, "[automation-e2e] bringing up portal + signed and runbook runners (profile: test)...")
	if err := compose(ctx, "up", "-d", "--wait", "--wait-timeout", "120", "portal"); err != nil {
		return err
	}
	if err := compose(ctx, "up", "-d", "--force-recreate", "signing-init", "runner-signed", "runner-runbook"); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, env, "go", "run", "./tools/cmd/signing-e2e"); err != nil {
		// Preserve the disposable fleet's failure evidence before the deferred
		// down removes it. Bound diagnostics independently so a wedged Docker
		// daemon cannot hide the original E2E error indefinitely.
		diagnosticCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = compose(diagnosticCtx, "ps", "-a")
		_ = compose(diagnosticCtx, "logs", "--tail", "200", "runner-runbook", "runner-signed", "portal")
		return err
	}
	return nil
}

var envKeyPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var paddleCustomerIDPattern = regexp.MustCompile(`^ctm_[A-Za-z0-9]+$`)

func parseEnvFile(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for lineNumber := 1; scanner.Scan(); lineNumber++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		key, value, found := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if !found || !envKeyPattern.MatchString(key) {
			return nil, fmt.Errorf("%s:%d: expected KEY=VALUE", path, lineNumber)
		}
		if len(value) >= 2 && ((value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"')) {
			value = value[1 : len(value)-1]
		}
		values[key] = value
	}
	return values, scanner.Err()
}

func requireValues(values map[string]string, keys ...string) error {
	for _, key := range keys {
		if values[key] == "" {
			return fmt.Errorf("required %s is not set", key)
		}
	}
	return nil
}

func stopProcess(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	_ = stopProcessGroup(command, false)
	done := make(chan struct{})
	go func() {
		_ = command.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = stopProcessGroup(command, true)
		<-done
	}
}

type ngrokTunnelResponse struct {
	Tunnels []struct {
		PublicURL string `json:"public_url"`
		Config    struct {
			Address string `json:"addr"`
		} `json:"config"`
	} `json:"tunnels"`
}

func targetsLocalPort(raw string, port int) bool {
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return (host == "localhost" || host == "127.0.0.1") && parsed.Port() == strconv.Itoa(port)
}

func ngrokTunnel() (string, error) {
	client := &http.Client{Timeout: 3 * time.Second}
	response, err := client.Get("http://127.0.0.1:4040/api/tunnels")
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return "", fmt.Errorf("ngrok API: HTTP %s", response.Status)
	}
	var result ngrokTunnelResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return "", err
	}
	for _, tunnel := range result.Tunnels {
		if strings.HasPrefix(tunnel.PublicURL, "https://") && targetsLocalPort(tunnel.Config.Address, 4000) {
			return tunnel.PublicURL, nil
		}
	}
	return "", fmt.Errorf("no HTTPS ngrok tunnel targets localhost:4000")
}

func patchPaddleDestination(ctx context.Context, values map[string]string, tunnel string) error {
	payload, _ := json.Marshal(map[string]any{"destination": tunnel + "/webhooks/paddle", "active": true})
	endpoint := "https://sandbox-api.paddle.com/notification-settings/" + url.PathEscape(values["PADDLE_E2E_NTFSET"])
	request, err := http.NewRequestWithContext(ctx, http.MethodPatch, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+values["PADDLE_API_KEY"])
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("reading the Paddle notification destination: HTTP %s: %s", response.Status, body)
	}
	return nil
}

func findPaddleCustomer(ctx context.Context, apiKey, email string) (string, error) {
	endpoint := "https://sandbox-api.paddle.com/customers?email=" + url.QueryEscape(email) + "&status=active&per_page=10"
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return "", fmt.Errorf("looking up the Paddle customer: HTTP %s: %s", response.Status, body)
	}
	var result struct {
		Data []struct {
			ID    string `json:"id"`
			Email string `json:"email"`
		} `json:"data"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return "", err
	}
	for _, customer := range result.Data {
		if strings.EqualFold(customer.Email, email) {
			if !paddleCustomerIDPattern.MatchString(customer.ID) {
				return "", fmt.Errorf("invalid customer id from Paddle")
			}
			return customer.ID, nil
		}
	}
	return "", nil
}

func (a *App) e2eBilling(ctx context.Context) error {
	if err := a.seed(ctx); err != nil {
		return err
	}
	workspace, err := a.loadWorkspace(ctx)
	if err != nil {
		return err
	}
	values, err := parseEnvFile(filepath.Join(a.Portal, ".agent", "secrets", "paddle-sandbox.env"))
	if err != nil {
		return fmt.Errorf("reading Paddle sandbox credentials: %w", err)
	}
	if err := requireValues(values, "PADDLE_API_KEY", "PADDLE_CLIENT_TOKEN", "PADDLE_WEBHOOK_SECRET", "PADDLE_E2E_NTFSET"); err != nil {
		return err
	}
	if !strings.Contains(values["PADDLE_API_KEY"], "_sdbx_") {
		return fmt.Errorf("refusing to run the e2e against a non-sandbox Paddle key")
	}
	lock, err := a.serveLock(4000, "http://localhost:4000")
	if err != nil {
		return err
	}
	defer func() { _ = unlockFile(lock); _ = lock.Close() }()
	if portListening(4000) {
		return fmt.Errorf("localhost:4000 is already in use")
	}
	env := a.workspaceEnv(workspace)
	env["PGPASSWORD"] = "postgres"
	deleteSQL := `
delete from billing_subscriptions where account_id = (select id from accounts where slug='demo');
update accounts
set paddle_customer_id = null, paddle_customer_synced_at = null
where slug = 'demo' and paddle_customer_id like 'ctm_stub_%';`
	if err := a.run(ctx, a.Root, env, "psql", "-U", "postgres", "-d", "emisar_dev", "-qc", deleteSQL); err != nil {
		return err
	}
	existingCustomer, err := findPaddleCustomer(ctx, values["PADDLE_API_KEY"], "demo@emisar.dev")
	if err != nil {
		return err
	}
	if existingCustomer != "" {
		relinkSQL := fmt.Sprintf("update accounts set paddle_customer_id = '%s', paddle_customer_synced_at = null where slug = 'demo';", existingCustomer)
		if err := a.run(ctx, a.Root, env, "psql", "-U", "postgres", "-d", "emisar_dev", "-qc", relinkSQL); err != nil {
			return err
		}
	}

	var ngrok *exec.Cmd
	tunnel, tunnelErr := ngrokTunnel()
	if tunnelErr != nil {
		logPath := filepath.Join(a.cacheRoot(), "ngrok-billing.log")
		logFile, openErr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if openErr != nil {
			return openErr
		}
		ngrok = exec.Command("ngrok", "http", "4000")
		ngrok.Stdout, ngrok.Stderr = logFile, logFile
		configureProcessGroup(ngrok)
		if err := ngrok.Start(); err != nil {
			logFile.Close()
			return err
		}
		logFile.Close()
		defer stopProcess(ngrok)
		for range 40 {
			tunnel, tunnelErr = ngrokTunnel()
			if tunnelErr == nil {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
	}
	if tunnelErr != nil || tunnel == "" {
		return fmt.Errorf("no ngrok tunnel: %w", tunnelErr)
	}
	if err := patchPaddleDestination(ctx, values, tunnel); err != nil {
		return err
	}
	for key, value := range values {
		env[key] = value
	}
	env["EMISAR_DEV_URL"] = "http://localhost:4000"
	env["EMISAR_LISTEN_IP"] = "127.0.0.1"
	env["EMISAR_LISTEN_PORT"] = "4000"
	env["EMISAR_DISABLE_BILLING"] = "false"
	serverLogPath := filepath.Join(a.cacheRoot(), "phoenix-billing.log")
	serverLog, err := os.OpenFile(serverLogPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	server := exec.Command("mix", "phx.server")
	server.Dir = a.Portal
	server.Env = toolutil.MergedEnv(env)
	server.Stdout, server.Stderr = serverLog, serverLog
	configureProcessGroup(server)
	if err := server.Start(); err != nil {
		serverLog.Close()
		return err
	}
	serverLog.Close()
	defer stopProcess(server)
	client := &http.Client{Timeout: 3 * time.Second}
	if err := waitUntil(ctx, 90, 2*time.Second, func() error {
		response, requestErr := client.Get("http://localhost:4000/healthz")
		if requestErr != nil {
			return requestErr
		}
		response.Body.Close()
		if response.StatusCode/100 != 2 {
			return fmt.Errorf("HTTP %s", response.Status)
		}
		return nil
	}); err != nil {
		return fmt.Errorf("billing dev server never came up; see %s: %w", serverLogPath, err)
	}
	response, err := client.Get("http://localhost:4000/checkout")
	if err != nil {
		return err
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if !bytes.Contains(body, []byte(`data-sandbox="true"`)) {
		return fmt.Errorf("/checkout is not running sandbox Paddle.js")
	}
	manager, _, err := a.startBrowser(ctx)
	if err != nil {
		return err
	}
	if err := devbrowser.PaddlePurchase(ctx, manager, devbrowser.PaddleConfig{
		BaseURL: "http://localhost:4000", Out: filepath.Join(a.Root, "test-results", "paddle-e2e"),
		Log: a.Out,
	}); err != nil {
		return err
	}
	query := "select plan || '|' || status || '|' || entitlements::text from billing_subscriptions where account_id = (select id from accounts where slug='demo');"
	row := ""
	for range 45 {
		output, queryErr := a.output(ctx, a.Root, env, "psql", "-U", "postgres", "-d", "emisar_dev", "-Atc", query)
		if queryErr == nil {
			row = strings.TrimSpace(string(output))
			if row != "" {
				break
			}
		}
		time.Sleep(2 * time.Second)
	}
	if !strings.HasPrefix(row, "team|") || !strings.Contains(row, "runners_limit") {
		return fmt.Errorf("unexpected mirrored subscription state: %s", row)
	}
	fmt.Fprintln(a.Out, "PASS: sandbox purchase mirrored plan=team with entitlements")
	return nil
}

func (a *App) e2e(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return usage("usage: ./run e2e <sso|signing|billing>")
	}
	switch args[0] {
	case "sso":
		return a.e2eSSO(ctx)
	case "signing":
		return a.e2eSigning(ctx)
	case "billing":
		return a.e2eBilling(ctx)
	default:
		return usage("usage: ./run e2e <sso|signing|billing>")
	}
}
