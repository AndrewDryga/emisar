package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// connect and disconnect own the whole post-install phase: detect the LLM
// clients on this machine, run one browser approval for the direct CLI and
// every selected client, and write each client's own configuration shape. The
// install scripts place the binary and delegate here, so one implementation
// serves macOS, Linux, and Windows instead of three.

type connectOptions struct {
	origin     string
	clientIDs  []string
	all        bool
	assumeYes  bool
	autoPermit bool
	forget     bool
}

func runConnectCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	options, err := parseConnectArgs(args, false)
	if err != nil {
		return cliUsageBlock(stderr, err.Error(), connectUsageText)
	}
	if options.help {
		fmt.Fprint(stdout, connectHelpText)
		return 0
	}
	return connectClients(options.connectOptions, stdin, stdout, stderr, newDeviceAuthenticator())
}

func runDisconnectCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	options, err := parseConnectArgs(args, true)
	if err != nil {
		return cliUsageBlock(stderr, err.Error(), disconnectUsageText)
	}
	if options.help {
		fmt.Fprint(stdout, disconnectHelpText)
		return 0
	}
	return disconnectClients(options.connectOptions, stdin, stdout, stderr)
}

type parsedConnectArgs struct {
	connectOptions
	help bool
}

func parseConnectArgs(args []string, disconnect bool) (parsedConnectArgs, error) {
	parsed := parsedConnectArgs{}
	for index := 0; index < len(args); index++ {
		switch argument := args[index]; argument {
		case "-h", "--help":
			parsed.help = true
		case "--all":
			parsed.all = true
		case "--yes":
			// Connect never consulted the flag — --all is the no-prompt path — so
			// it is disconnect-only rather than a documented no-op.
			if !disconnect {
				return parsed, fmt.Errorf("unknown option %q", argument)
			}
			parsed.assumeYes = true
		case "--auto-permit":
			if disconnect {
				return parsed, fmt.Errorf("unknown option %q", argument)
			}
			parsed.autoPermit = true
		case "--forget":
			if !disconnect {
				return parsed, fmt.Errorf("unknown option %q", argument)
			}
			parsed.forget = true
		case "--client":
			index++
			if index >= len(args) {
				return parsed, errors.New("--client needs a client id")
			}
			if _, known := lookupClientAdapter(args[index]); !known {
				return parsed, fmt.Errorf("unknown client %q", displayCLIOption(args[index]))
			}
			parsed.clientIDs = append(parsed.clientIDs, args[index])
		case "--url":
			if disconnect {
				return parsed, fmt.Errorf("unknown option %q", argument)
			}
			index++
			if index >= len(args) {
				return parsed, errors.New("--url needs an Emisar server origin")
			}
			parsed.origin = args[index]
		default:
			return parsed, fmt.Errorf("unknown option %q", displayCLIOption(argument))
		}
	}
	if parsed.all && len(parsed.clientIDs) > 0 {
		return parsed, errors.New("--all cannot be combined with --client")
	}
	return parsed, nil
}

// connectSelection is what the operator (or a flag) chose to configure.
type connectSelection struct {
	clients    []detectedClient
	cliNeeded  bool
	autoPermit bool
}

func connectClients(
	options connectOptions,
	stdin io.Reader,
	stdout, stderr io.Writer,
	authenticator deviceAuthenticator,
) int {
	command, err := os.Executable()
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not determine this bridge's own path",
			[]string{err.Error()},
			"Reinstall emisar-mcp, then run `emisar-mcp connect` again.",
		)
	}
	origin, err := resolveConnectOrigin(options.origin)
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not choose an Emisar server",
			[]string{err.Error()},
			"Pass an origin such as `emisar-mcp connect --url https://emisar.dev`.",
		)
	}
	roots, err := currentConfigRoots()
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not locate your home directory",
			[]string{err.Error()},
			"Set HOME (or USERPROFILE on Windows) and run `emisar-mcp connect` again.",
		)
	}

	clients := detectClients(roots)
	cliNeeded := !storedCLICredentialWorks(origin)
	printConnectionTable(stdout, clients, cliNeeded, origin)

	selection, ok := selectClients(options, clients, cliNeeded, stdin, stdout)
	if !ok {
		fmt.Fprintln(stdout, "Nothing selected. Connect a client later with `emisar-mcp connect`.")
		return 0
	}
	if len(selection.clients) == 0 && !selection.cliNeeded {
		fmt.Fprintln(stdout, "Everything detected is already connected.")
		return 0
	}

	preflightFailures := 0
	for _, client := range selection.clients {
		request := clientEntryRequest{
			Command:    command,
			Origin:     origin,
			ClientID:   client.ID,
			AutoPermit: selection.autoPermit && client.autoPermit != autoPermitNone,
		}
		if err := client.preflight(request); err != nil {
			preflightFailures++
			writeCLIWarning(
				stderr,
				client.Label+": could not safely update "+client.ConfigFile,
				[]string{err.Error()},
				"No approval was requested. Fix this config, then run `emisar-mcp connect` again.",
			)
		}
	}
	if preflightFailures > 0 {
		return 1
	}

	requested := make([]string, 0, len(selection.clients)+1)
	if selection.cliNeeded {
		requested = append(requested, deviceAuthClientID)
	}
	for _, client := range selection.clients {
		requested = append(requested, client.ID)
	}

	fmt.Fprintln(stdout)
	response, err := authenticator.authorize(context.Background(), origin, requested, "this machine", stdout)
	if err != nil {
		return connectAuthorizationError(stderr, err, origin)
	}

	// Validate every delivered key before writing anything: a partial response
	// must not leave some clients connected from a grant already consumed.
	keys := make(map[string]string, len(requested))
	for _, id := range requested {
		key, err := response.clientKey(id)
		if err != nil {
			return cliCommandError(
				stderr,
				"The approval response was incomplete",
				[]string{err.Error()},
				"Nothing was configured. Run `emisar-mcp connect` again.",
			)
		}
		keys[id] = key
	}

	failures := 0
	if selection.cliNeeded {
		credential, err := response.cliCredential()
		if err != nil {
			return cliCommandError(
				stderr,
				"The approval response was incomplete",
				[]string{err.Error()},
				"Nothing was configured. Run `emisar-mcp connect` again.",
			)
		}
		if code := storeCLIAccountCredential(origin, credential, io.Discard, stderr); code != 0 {
			failures++
		} else {
			printClientRow(stdout, "Emisar CLI", cliStyleConnected, "authenticated")
		}
	}

	for _, client := range selection.clients {
		request := clientEntryRequest{
			Command:    command,
			Origin:     origin,
			APIKey:     keys[client.ID],
			ClientID:   client.ID,
			AutoPermit: selection.autoPermit && client.autoPermit != autoPermitNone,
		}
		if err := client.install(request); err != nil {
			failures++
			writeCLIWarning(
				stderr,
				client.Label+": could not update "+client.ConfigFile,
				[]string{err.Error()},
				"Paste its snippet from "+origin+"/app/agents/connect instead.",
			)
			continue
		}
		if request.AutoPermit {
			if err := client.applyAutoPermit(roots); err != nil {
				writeCLIWarning(
					stderr,
					client.Label+" is connected, but its per-tool prompt stayed on",
					[]string{err.Error()},
					"Silence it by hand, or leave it — Emisar still decides every call server-side.",
				)
			}
		}
		printClientRow(stdout, client.Label, cliStyleConnected, "connected → "+client.ConfigFile)
	}

	fmt.Fprintln(stdout)
	if failures > 0 {
		fmt.Fprintln(stdout, "Some clients were not connected. Manual snippets: "+origin+"/app/agents/connect")
		return 1
	}
	fmt.Fprintln(stdout, "Restart any client you just connected so it picks up the new server.")
	return 0
}

func disconnectClients(options connectOptions, stdin io.Reader, stdout, stderr io.Writer) int {
	roots, err := currentConfigRoots()
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not locate your home directory",
			[]string{err.Error()},
			"Set HOME (or USERPROFILE on Windows) and run `emisar-mcp disconnect` again.",
		)
	}
	clients := detectClients(roots)
	connected := make([]detectedClient, 0, len(clients))
	for _, client := range clients {
		if client.Connected && (options.all || len(options.clientIDs) == 0 || containsString(options.clientIDs, client.ID)) {
			connected = append(connected, client)
		}
	}
	if len(connected) == 0 && !options.forget {
		fmt.Fprintln(stdout, "No connected clients found.")
		return 0
	}
	if !options.assumeYes && !options.all && len(options.clientIDs) == 0 {
		reader := bufio.NewReader(stdin)
		if !readerIsTerminal(stdin) {
			return cliInputError(
				stderr,
				"Refusing to remove client entries without a confirmation",
				"Pass --all or --client <id>, or run this from a terminal.",
			)
		}
		for _, client := range connected {
			fmt.Fprintln(stdout, "  "+client.Label+": "+client.ConfigFile)
		}
		if !askYesNo(reader, stdout, "Remove the emisar entry from these clients?") {
			fmt.Fprintln(stdout, "Nothing was removed.")
			return 0
		}
	}

	failures := 0
	for _, client := range connected {
		if err := client.remove(); err != nil {
			failures++
			writeCLIWarning(
				stderr,
				client.Label+": could not remove the emisar entry from "+client.ConfigFile,
				[]string{err.Error()},
				"Remove it by hand.",
			)
			continue
		}
		if err := client.removeAutoPermit(roots); err != nil {
			writeCLIWarning(
				stderr,
				client.Label+": left its emisar auto-permit entry in place",
				[]string{err.Error()},
				"Remove it by hand.",
			)
		}
		fmt.Fprintln(stdout, "Removed emisar from "+client.Label+": "+client.ConfigFile)
	}

	if options.forget {
		removed, err := removeStoredCredentials()
		if err != nil {
			failures++
			writeCLIWarning(
				stderr,
				"Could not remove stored CLI accounts and rotation state",
				[]string{err.Error()},
				"Remove the emisar credentials directory by hand.",
			)
		} else if removed != "" {
			fmt.Fprintln(stdout, "Removed stored CLI accounts and rotation state: "+removed)
		}
	}
	if failures > 0 {
		return 1
	}
	return 0
}

// selectClients resolves flags and prompts into the set to configure. The
// second result is false when the operator chose nothing at all.
func selectClients(
	options connectOptions,
	clients []detectedClient,
	cliNeeded bool,
	stdin io.Reader,
	stdout io.Writer,
) (connectSelection, bool) {
	selection := connectSelection{cliNeeded: cliNeeded, autoPermit: options.autoPermit}
	candidates := make([]detectedClient, 0, len(clients))
	for _, client := range clients {
		if !client.Connected {
			candidates = append(candidates, client)
		}
	}

	switch {
	case len(options.clientIDs) > 0:
		for _, client := range clients {
			if containsString(options.clientIDs, client.ID) {
				selection.clients = append(selection.clients, client)
			}
		}
		return selection, len(selection.clients) > 0 || cliNeeded
	case options.all:
		selection.clients = candidates
		return selection, true
	}

	if !readerIsTerminal(stdin) {
		// Without a terminal there is nobody to ask, and connecting a client the
		// operator did not name would be a surprise edit to their config.
		if cliNeeded {
			return selection, true
		}
		fmt.Fprintln(stdout, "Run this from a terminal, or pass --all or --client <id>, to connect a client.")
		return selection, false
	}

	reader := bufio.NewReader(stdin)
	fmt.Fprintln(stdout)
	for _, client := range candidates {
		if askYesNo(reader, stdout, "Add emisar to "+client.Label+"?") {
			selection.clients = append(selection.clients, client)
		}
	}

	// Asked once, after the per-client questions and before anything is written.
	// Emisar decides every call server-side, so a client's own prompt adds
	// nothing for OUR tools — but it is the operator's setting in the operator's
	// file, so it stays opt-in and is never implied by --all.
	if !options.autoPermit {
		var labels []string
		for _, client := range selection.clients {
			if client.autoPermit != autoPermitNone {
				labels = append(labels, client.Label)
			}
		}
		if len(labels) > 0 {
			fmt.Fprintln(stdout)
			fmt.Fprintln(stdout, "Emisar decides every action on the server, so a client's own \"allow this tool?\" prompt adds nothing for Emisar's tools. Policy and approvals still apply.")
			selection.autoPermit = askYesNo(
				reader,
				stdout,
				"Silence that prompt for the emisar server only in "+strings.Join(labels, ", ")+"?",
			)
		}
	}
	return selection, len(selection.clients) > 0 || cliNeeded
}

const (
	cliStyleConnected = "1;32"
	cliStyleMuted     = "2"
	cliStylePending   = "33"
)

func printConnectionTable(stdout io.Writer, clients []detectedClient, cliNeeded bool, origin string) {
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, cliStyledText(stdout, "1", "Connect emisar"))
	fmt.Fprintln(stdout)
	if cliNeeded {
		printClientRow(stdout, "Emisar CLI", cliStylePending, "not authenticated")
	} else {
		printClientRow(stdout, "Emisar CLI", cliStyleMuted, "credential verified")
	}
	for _, client := range clients {
		if client.Connected {
			printClientRow(stdout, client.Label, cliStyleMuted, "already connected")
		} else {
			printClientRow(stdout, client.Label, cliStylePending, "not connected")
		}
	}
	if len(clients) == 0 {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, "No supported LLM clients found — the direct CLI can still be connected.")
		fmt.Fprintln(stdout, "Connect a client later from "+origin+"/app/agents.")
	}
}

func printClientRow(stdout io.Writer, label, style, text string) {
	fmt.Fprintf(stdout, "  %-15s %s\n", label, cliStyledText(stdout, style, terminalSafeLine(text)))
}

func askYesNo(reader *bufio.Reader, stdout io.Writer, question string) bool {
	fmt.Fprint(stdout, question+" [y/N] ")
	answer, err := reader.ReadString('\n')
	if err != nil && answer == "" {
		fmt.Fprintln(stdout)
		return false
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	default:
		return false
	}
}

// resolveConnectOrigin prefers the explicit flag, then the ambient EMISAR_URL a
// self-hosted install command sets, then the stored account, then the default.
func resolveConnectOrigin(raw string) (string, error) {
	if raw == "" {
		raw = os.Getenv("EMISAR_URL")
	}
	// Every credential decision below reads per-account stored state. An ambient
	// key must not steer it, and this command never authenticates with one.
	_ = os.Unsetenv("EMISAR_URL")
	_ = os.Unsetenv("EMISAR_API_KEY")
	if raw != "" {
		return parseEndpoint(raw, allowInsecureEndpoints())
	}
	return resolveCLIAuthOrigin("", "")
}

func currentConfigRoots() (configRoots, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return configRoots{}, err
	}
	return resolveConfigRoots(home), nil
}

// storedCLICredentialWorks reports whether a direct CLI command would succeed
// against this origin right now, so a rerun over a healthy credential stays
// hands-off. Only an explicit rejection counts as failure: a network blip must
// not drag the operator through a fresh browser approval.
func storedCLICredentialWorks(origin string) bool {
	bridge, err := newBridgeFromEnv("emisar-mcp-cli", true, "", io.Discard)
	if err != nil || bridge.portalOrigin != origin {
		return false
	}
	response, _, err := bridge.cliRoundTrip("tools/list", "", nil)
	switch {
	case bridge.authRejected.Load():
		return false
	case err != nil:
		return true
	default:
		return len(response.Error) == 0
	}
}

// removeStoredCredentials drops every stored CLI account and the bridge's
// rotation state, the way the runner uninstall removes its cached identity.
func removeStoredCredentials() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	directory := filepath.Join(configDir, "emisar", "credentials")
	if _, err := os.Stat(directory); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	if err := os.RemoveAll(directory); err != nil {
		return "", err
	}
	return directory, nil
}

func connectAuthorizationError(stderr io.Writer, err error, origin string) int {
	switch {
	case errors.Is(err, errBrowserAuthUnsupported):
		return cliCommandError(
			stderr,
			"Browser approval is not available",
			[]string{"The server at " + origin + " does not provide browser approval."},
			"For a self-hosted server, upgrade it and make sure `/api/mcp/device_authorization` is routed.",
			"Or paste the manual client snippets from "+origin+"/app/agents/connect.",
		)
	case errors.Is(err, context.Canceled):
		return cliCommandError(
			stderr,
			"Browser approval was cancelled",
			[]string{"Nothing was configured."},
			"Run `emisar-mcp connect` when you are ready to try again.",
		)
	default:
		return cliCommandError(
			stderr,
			"Browser approval failed",
			[]string{err.Error()},
			"Check the server URL and your network connection, then run `emisar-mcp connect` again.",
		)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func sortedClientIDs() string {
	ids := clientAdapterIDs()
	sort.Strings(ids)
	return strings.Join(ids, ", ")
}

const connectUsageText = `usage:
  emisar-mcp connect [--url <origin>] [--all | --client <id>] [--auto-permit]`

const disconnectUsageText = `usage:
  emisar-mcp disconnect [--all | --client <id>] [--yes] [--forget]`

var connectHelpText = `emisar-mcp connect - authenticate this machine and configure LLM clients

USAGE
  emisar-mcp connect [--url <origin>] [--all | --client <id>] [--auto-permit]

WHAT IT DOES
  Detects the supported LLM clients installed for your user, runs one browser
  approval covering the direct CLI and every client you choose, and writes each
  client's own configuration shape. --all leaves connected clients alone;
  explicitly naming one with --client refreshes its key and server URL.

FLAGS
  --url <origin>
    The Emisar server to connect to. Defaults to the stored account, then
    https://emisar.dev.

  --all
    Connect every detected client that is not connected yet, without asking.

  --client <id>
    Connect or refresh one client by id; repeatable. Ids: ` + sortedClientIDs() + `

  --auto-permit
    Also silence the client's own "allow this tool?" prompt, for the emisar
    server only. Emisar still decides every call server-side.

NOTES
  Restart a client after connecting it. Reconnecting does not revoke old keys;
  revoke them in the portal under LLM agents.
`

var disconnectHelpText = `emisar-mcp disconnect - remove emisar from LLM clients

USAGE
  emisar-mcp disconnect [--all | --client <id>] [--yes] [--forget]

WHAT IT DOES
  Removes the emisar entry, and the backup this bridge wrote, from every
  detected client that carries one. Other settings in those files are left
  exactly as they are.

FLAGS
  --all
    Remove from every connected client without asking.

  --client <id>
    Remove from one client by id; repeatable. Ids: ` + sortedClientIDs() + `

  --yes
    Do not ask for confirmation.

  --forget
    Also delete every stored direct-CLI account and the bridge's rotation state.

NOTES
  A key removed from a config keeps working until it is revoked in the portal
  under LLM agents.
`
