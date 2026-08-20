package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const maxCredentialInputBytes = 1 << 10

func runAuthCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	switch {
	case len(args) == 0:
		return showCLIAuthStatus("", stdout, stderr)
	case len(args) == 1 && args[0] == "status":
		return showCLIAuthStatus("", stdout, stderr)
	case len(args) == 2 && args[0] == "status":
		return showCLIAuthStatus(args[1], stdout, stderr)
	case len(args) == 2 && args[0] == "import":
		return importCLIAuth(args[1], stdin, stdout, stderr)
	case len(args) == 1 && (args[0] == "-h" || args[0] == "--help"):
		fmt.Fprint(stdout, authHelpText)
		return 0
	default:
		fmt.Fprint(stderr, authUsageText)
		return 2
	}
}

func showCLIAuthStatus(expectedOrigin string, stdout, stderr io.Writer) int {
	store, state, err := loadCLICredential()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(stderr, "emisar-mcp: no stored CLI credential; run install-mcp.sh interactively")
		} else {
			fmt.Fprintf(stderr, "emisar-mcp: stored CLI credential: %v\n", err)
		}
		return 1
	}
	if expectedOrigin != "" {
		expected, err := parseEndpoint(expectedOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
		if err != nil {
			fmt.Fprintf(stderr, "emisar-mcp: %v\n", err)
			return 1
		}
		if expected != state.EndpointOrigin {
			fmt.Fprintf(stderr, "emisar-mcp: stored CLI credential is for %s, not %s\n", state.EndpointOrigin, expected)
			return 1
		}
	}
	fmt.Fprintf(stdout, "Credential stored for %s (%s)\n", state.EndpointOrigin, store.path)
	return 0
}

func importCLIAuth(rawOrigin string, stdin io.Reader, stdout, stderr io.Writer) int {
	origin, err := parseEndpoint(rawOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
	if err != nil {
		fmt.Fprintf(stderr, "emisar-mcp: %v\n", err)
		return 1
	}
	data, err := io.ReadAll(io.LimitReader(stdin, maxCredentialInputBytes+1))
	if err != nil {
		fmt.Fprintf(stderr, "emisar-mcp: read API key: %v\n", err)
		return 1
	}
	if len(data) > maxCredentialInputBytes {
		fmt.Fprintf(stderr, "emisar-mcp: API key input exceeds %d bytes\n", maxCredentialInputBytes)
		return 1
	}
	apiKey := strings.TrimSpace(string(data))
	if !validAPIKey(apiKey) {
		fmt.Fprintln(stderr, "emisar-mcp: stdin must contain one valid emk- API key")
		return 1
	}
	store, err := newCLICredentialStore(origin, keyPrefix(apiKey))
	if err != nil {
		fmt.Fprintf(stderr, "emisar-mcp: locate user config directory: %v\n", err)
		return 1
	}
	state := credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  origin,
		BootstrapPrefix: keyPrefix(apiKey),
		Current:         apiKey,
	}
	var replacedOrigin string
	err = store.withLock(func() error {
		if err := store.validateExistingPath(); err != nil {
			return err
		}
		if data, readErr := store.ops.readFile(store.path); readErr == nil {
			previous, decodeErr := decodeCredentialState(data)
			if decodeErr == nil && (previous.Current != apiKey || previous.EndpointOrigin != origin) {
				if parsed, parseErr := parseEndpoint(previous.EndpointOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1"); parseErr == nil {
					replacedOrigin = parsed
				}
			}
		} else if !errors.Is(readErr, os.ErrNotExist) {
			return fmt.Errorf("read credential state: %w", readErr)
		}
		return store.persist(state)
	})
	if err != nil {
		fmt.Fprintf(stderr, "emisar-mcp: store CLI credential: %v\n", err)
		return 1
	}
	if replacedOrigin != "" {
		fmt.Fprintf(stderr, "emisar-mcp: replaced the stored CLI credential for %s; if the old key connected, revoke it in %s/app/agents; unused installer keys stay hidden and expire after 30 days\n", replacedOrigin, replacedOrigin)
	}
	fmt.Fprintf(stdout, "Credential stored for %s\n", origin)
	return 0
}

func loadCLICredential() (*credentialStore, credentialState, error) {
	store, err := newCLICredentialStore("", "")
	if err != nil {
		return nil, credentialState{}, err
	}
	if err := store.validateExistingPath(); err != nil {
		return nil, credentialState{}, err
	}
	data, err := store.ops.readFile(store.path)
	if err != nil {
		return nil, credentialState{}, fmt.Errorf("read credential state: %w", err)
	}
	state, err := decodeCredentialState(data)
	if err != nil {
		return nil, credentialState{}, err
	}
	origin, err := parseEndpoint(state.EndpointOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
	if err != nil {
		return nil, credentialState{}, fmt.Errorf("credential state endpoint: %w", err)
	}
	store.endpointOrigin = origin
	store.bootstrapPrefix = state.BootstrapPrefix
	if err := state.validate(origin, store.bootstrapPrefix); err != nil {
		return nil, credentialState{}, err
	}
	return store, state, nil
}

const authUsageText = `usage:
  emisar-mcp auth [status [URL]]
  emisar-mcp auth import URL
`

const authHelpText = `emisar-mcp auth - manage the installed direct-CLI credential

USAGE
  emisar-mcp auth
  emisar-mcp auth status [URL]
  emisar-mcp auth import URL

DESCRIPTION
  With no subcommand, show whether a direct-CLI credential is stored and its
  endpoint. Add URL to status to require an exact endpoint match. This is a
  local state check, not a request to the control plane. Import reads one emk-
  API key from stdin and stores it in the owner-only credential state used by
  direct commands.

  Import replaces the one stored CLI credential. It does not revoke the old
  server-side key. If that key connected, revoke it in the old endpoint's
  /app/agents page. Unused installer keys stay hidden and expire after 30 days.

  Interactive install-mcp.sh runs import automatically after browser approval.
  Stdio MCP clients never use this credential; they still require EMISAR_URL
  and EMISAR_API_KEY in their own client configuration.
`
