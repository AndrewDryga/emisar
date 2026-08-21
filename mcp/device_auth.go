package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

const (
	deviceAuthClientID        = "emisar-mcp-cli"
	maxDeviceAuthResponse     = 16 << 10
	deviceAuthRequestTimeout  = 15 * time.Second
	minDeviceAuthExpires      = 60
	maxDeviceAuthExpires      = 3_600
	minDeviceAuthPollInterval = 1
	maxDeviceAuthPollInterval = 120
)

var errBrowserAuthUnsupported = errors.New("server does not support direct CLI browser authentication")

type deviceAuthenticator struct {
	client      *http.Client
	openBrowser func(string) bool
	stdoutIsTTY func(io.Writer) bool
	now         func() time.Time
	wait        func(context.Context, time.Duration) error
}

type deviceAuthorization struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

type deviceTokenResponse struct {
	AccountID   string            `json:"account_id"`
	AccountSlug string            `json:"account_slug"`
	AccountName string            `json:"account_name"`
	ClientKeys  map[string]string `json:"client_keys"`
	Error       string            `json:"error"`
}

type deviceCredential struct {
	APIKey      string
	AccountID   string
	AccountSlug string
	AccountName string
}

func newDeviceAuthenticator() deviceAuthenticator {
	return deviceAuthenticator{
		client:      newHTTPClient(),
		openBrowser: openBrowserURL,
		stdoutIsTTY: writerIsTerminal,
		now:         time.Now,
		wait:        waitForDevicePoll,
	}
}

func loginCLIAuth(
	account, rawOrigin string,
	stdout, stderr io.Writer,
	authenticator deviceAuthenticator,
) int {
	origin, err := resolveCLIAuthOrigin(account, rawOrigin)
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not choose an Emisar server",
			[]string{err.Error()},
			"Pass an origin such as `emisar-mcp auth login https://emisar.dev`.",
			"Run `emisar-mcp accounts list` to see stored accounts.",
		)
	}
	credential, err := authenticator.authorize(context.Background(), origin, stdout)
	if err != nil {
		switch {
		case errors.Is(err, errBrowserAuthUnsupported):
			return cliCommandError(
				stderr,
				"Browser sign-in is not available",
				[]string{"The server at " + origin + " does not provide browser sign-in directly to the CLI."},
				"Rerun the interactive MCP installer to authenticate this CLI on an older server.",
				"For a self-hosted server, upgrade it and make sure `/api/mcp/device_authorization` is routed.",
				"Or set EMISAR_URL and EMISAR_API_KEY together for direct commands.",
			)
		case errors.Is(err, context.Canceled):
			return cliCommandError(
				stderr,
				"Browser sign-in was cancelled",
				[]string{"No credential was saved."},
				"Run `emisar-mcp auth` when you are ready to try again.",
			)
		case strings.Contains(err.Error(), "denied"):
			return cliCommandError(
				stderr,
				"Browser sign-in was denied",
				[]string{"No credential was saved."},
				"Run `emisar-mcp auth` again and approve the request in your browser.",
			)
		case strings.Contains(err.Error(), "expired") || strings.Contains(err.Error(), "no longer valid"):
			return cliCommandError(
				stderr,
				"The browser sign-in code expired",
				[]string{"No credential was saved."},
				"Run `emisar-mcp auth` to start with a new code.",
			)
		default:
			return cliCommandError(
				stderr,
				"Browser sign-in failed",
				[]string{err.Error()},
				"Check the server URL and your network connection, then run `emisar-mcp auth` again.",
			)
		}
	}
	return storeCLIAccountCredential(origin, credential, stdout, stderr)
}

func (auth deviceAuthenticator) authorize(
	ctx context.Context,
	origin string,
	stdout io.Writer,
) (deviceCredential, error) {
	grant, err := auth.requestGrant(ctx, origin)
	if err != nil {
		return deviceCredential{}, err
	}

	fmt.Fprintln(stdout, "Approve Emisar CLI in your browser")
	fmt.Fprintln(stdout)
	fmt.Fprintf(
		stdout,
		"  %s\n",
		cliStyledText(stdout, "4", terminalSafeLine(grant.VerificationURIComplete)),
	)
	fmt.Fprintln(stdout)
	fmt.Fprintf(stdout, "If prompted, enter this code: %s\n", cliStyledText(stdout, "1;36", grant.UserCode))
	fmt.Fprintln(stdout)
	if auth.stdoutIsTTY(stdout) && auth.openBrowser(grant.VerificationURIComplete) {
		fmt.Fprintln(stdout, "Sent the link to your default browser. If it did not open, use the link above.")
	} else {
		fmt.Fprintln(stdout, "Open the link above in your browser.")
	}
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Waiting for approval (Ctrl-C to cancel)…")

	deadline := auth.now().Add(time.Duration(grant.ExpiresIn) * time.Second)
	for {
		remaining := deadline.Sub(auth.now())
		if remaining <= 0 {
			break
		}
		pollAfter := time.Duration(grant.Interval) * time.Second
		if pollAfter > remaining {
			pollAfter = remaining
		}
		if err := auth.wait(ctx, pollAfter); err != nil {
			return deviceCredential{}, err
		}
		if !auth.now().Before(deadline) {
			break
		}
		credential, pending, err := auth.poll(ctx, origin, grant.DeviceCode)
		if err != nil {
			return deviceCredential{}, err
		}
		if pending {
			continue
		}
		fmt.Fprintln(stdout)
		return credential, nil
	}
	return deviceCredential{}, errors.New("approval code expired; run auth again")
}

func (auth deviceAuthenticator) requestGrant(ctx context.Context, origin string) (deviceAuthorization, error) {
	body, err := json.Marshal(map[string][]string{"requested_clients": {deviceAuthClientID}})
	if err != nil {
		return deviceAuthorization{}, fmt.Errorf("encode device request: %w", err)
	}
	status, response, contentType, err := auth.postJSON(
		ctx,
		origin+"/api/mcp/device_authorization",
		body,
	)
	if err != nil {
		return deviceAuthorization{}, fmt.Errorf("start approval: %w", err)
	}
	if status != http.StatusOK {
		if status == http.StatusNotFound {
			return deviceAuthorization{}, errBrowserAuthUnsupported
		}
		if status == http.StatusBadRequest {
			var failure deviceTokenResponse
			if decodeDeviceJSON(response, contentType, &failure) == nil && failure.Error == "invalid_request" {
				return deviceAuthorization{}, errBrowserAuthUnsupported
			}
		}
		return deviceAuthorization{}, fmt.Errorf("start approval: HTTP %d", status)
	}
	var grant deviceAuthorization
	if err := decodeDeviceJSON(response, contentType, &grant); err != nil {
		return deviceAuthorization{}, fmt.Errorf("start approval response: %w", err)
	}
	if err := validateDeviceAuthorization(origin, grant); err != nil {
		return deviceAuthorization{}, fmt.Errorf("start approval response: %w", err)
	}
	return grant, nil
}

func (auth deviceAuthenticator) poll(
	ctx context.Context,
	origin, deviceCode string,
) (deviceCredential, bool, error) {
	body, err := json.Marshal(map[string]string{"device_code": deviceCode})
	if err != nil {
		return deviceCredential{}, false, fmt.Errorf("encode approval poll: %w", err)
	}
	status, response, contentType, err := auth.postJSON(
		ctx,
		origin+"/api/mcp/device_token",
		body,
	)
	if err != nil {
		return deviceCredential{}, true, nil
	}
	var result deviceTokenResponse
	switch status {
	case http.StatusOK:
		if decodeDeviceJSON(response, contentType, &result) != nil {
			return deviceCredential{}, true, nil
		}
		credential, err := result.cliCredential()
		if err != nil {
			return deviceCredential{}, false, errors.New("server returned an invalid approval response; run auth again")
		}
		return credential, false, nil
	case http.StatusBadRequest:
		if decodeDeviceJSON(response, contentType, &result) != nil || !validDeviceError(result.Error) {
			return deviceCredential{}, true, nil
		}
		switch result.Error {
		case "", "authorization_pending":
			return deviceCredential{}, true, nil
		case "access_denied":
			return deviceCredential{}, false, errors.New("approval was denied; no credential was stored")
		case "expired_token":
			return deviceCredential{}, false, errors.New("approval code expired; run auth again")
		case "invalid_grant":
			return deviceCredential{}, false, errors.New("approval code is no longer valid; run auth again")
		default:
			return deviceCredential{}, false, fmt.Errorf("server returned terminal error %q", result.Error)
		}
	default:
		return deviceCredential{}, true, nil
	}
}

func (response deviceTokenResponse) cliCredential() (deviceCredential, error) {
	credential := deviceCredential{
		APIKey:      response.ClientKeys[deviceAuthClientID],
		AccountID:   response.AccountID,
		AccountSlug: response.AccountSlug,
		AccountName: displayAccountName(response.AccountName),
	}
	if !validAPIKey(credential.APIKey) {
		return deviceCredential{}, errors.New("invalid CLI API key")
	}
	if err := validateAccountIdentity(
		credential.AccountID,
		credential.AccountSlug,
		credential.AccountName,
	); err != nil {
		return deviceCredential{}, err
	}
	return credential, nil
}

func (auth deviceAuthenticator) postJSON(
	ctx context.Context,
	endpoint string,
	body []byte,
) (int, []byte, string, error) {
	requestCtx, cancel := context.WithTimeout(ctx, deviceAuthRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return 0, nil, "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", buildUserAgentWithDefault(deviceAuthClientID))
	resp, err := auth.client.Do(req)
	if err != nil {
		return 0, nil, "", err
	}
	defer resp.Body.Close()
	response, err := readCappedBody(resp.Body, maxDeviceAuthResponse)
	if err != nil {
		return 0, nil, "", err
	}
	return resp.StatusCode, response, resp.Header.Get("Content-Type"), nil
}

func validateDeviceAuthorization(origin string, grant deviceAuthorization) error {
	switch {
	case !validDeviceCode(grant.DeviceCode):
		return errors.New("invalid device code")
	case !validDeviceUserCode(grant.UserCode):
		return errors.New("invalid user code")
	case !sameOriginBrowserURL(origin, grant.VerificationURI):
		return errors.New("invalid verification URL")
	case !sameOriginBrowserURL(origin, grant.VerificationURIComplete):
		return errors.New("invalid complete verification URL")
	case grant.ExpiresIn < minDeviceAuthExpires || grant.ExpiresIn > maxDeviceAuthExpires:
		return errors.New("invalid approval lifetime")
	case grant.Interval < minDeviceAuthPollInterval || grant.Interval > maxDeviceAuthPollInterval:
		return errors.New("invalid polling interval")
	default:
		return nil
	}
}

func validDeviceCode(value string) bool {
	return len(value) >= len("emdg-")+16 && len(value) <= 128 &&
		strings.HasPrefix(value, "emdg-") && asciiToken(value)
}

func validDeviceUserCode(value string) bool {
	if len(value) < 3 || len(value) > 32 {
		return false
	}
	for _, char := range value {
		if (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '-' {
			return false
		}
	}
	return true
}

func validDeviceError(value string) bool {
	return len(value) <= 40 && asciiToken(value)
}

func asciiToken(value string) bool {
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') && char != '-' && char != '_' && char != '.' {
			return false
		}
	}
	return true
}

func sameOriginBrowserURL(origin, raw string) bool {
	if terminalSafeText(raw) != raw {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || !u.IsAbs() || u.Opaque != "" || u.User != nil || u.Host == "" ||
		u.Fragment != "" || u.Path == "" {
		return false
	}
	parsedOrigin, err := parseEndpoint(u.Scheme+"://"+u.Host, true)
	return err == nil && parsedOrigin == origin
}

func decodeDeviceJSON(body []byte, contentType string, target any) error {
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil || mediaType != "application/json" {
		return errors.New("response is not JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return ensureJSONEOF(decoder)
}

func writerIsTerminal(writer io.Writer) bool {
	file, ok := writer.(*os.File)
	return ok && fileIsTerminal(file)
}

func waitForDevicePoll(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func openBrowserURL(rawURL string) bool {
	var name string
	var args []string
	switch runtime.GOOS {
	case "darwin":
		name, args = "open", []string{rawURL}
	case "linux":
		name, args = "xdg-open", []string{rawURL}
	case "windows":
		name, args = "rundll32.exe", []string{"url.dll,FileProtocolHandler", rawURL}
	default:
		return false
	}
	command := exec.Command(name, args...)
	if err := command.Start(); err != nil {
		return false
	}
	go func() { _ = command.Wait() }()
	return true
}
