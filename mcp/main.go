// Command emisar-mcp is a thin stdio↔HTTP shim for MCP-aware clients
// (Claude Desktop, Cursor, Claude Code, Gemini CLI, Codex CLI, Grok, …) that
// only speak stdio JSON-RPC.
//
// The bridge owns transport correctness: bounded newline framing, request-id
// correlation, Streamable HTTP headers, and validation that stdout contains
// only valid MCP messages. All tool descriptors, content blocks, and synthetic
// tools are produced by the portal. Stdio mode does not reinterpret them. The
// direct CLI adds bounded, terminal-safe views for the fixed tool contracts and
// may follow exact read-only continuations after a human-mode mutation; --json
// remains one logical invocation and follows no continuations. Bridge-attested
// dispatch (sign.go) recognizes only `run_action` and carries its signed intent
// signature in a private HTTP header, because the signing key must stay here and
// never reach the control plane.
//
// Configure your client to launch:
//
//	{
//	  "mcpServers": {
//	    "emisar": {
//	      "command": "/usr/local/bin/emisar-mcp",
//	      "env": {
//	        "EMISAR_URL":     "https://emisar.dev",
//	        "EMISAR_API_KEY": "emk-..."
//	      }
//	    }
//	  }
//	}
//
// If your client speaks MCP-over-HTTP natively (Claude / ChatGPT
// cloud connectors, recent Cursor / Continue / Zed), skip the bridge
// entirely and point them straight at `${EMISAR_URL}/api/mcp/rpc`
// with the same Bearer token.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const bridgeName = "emisar-mcp"

// The portal permits a wait to hold a request for 60 seconds. Keep 30 seconds
// of bounded transport headroom so its graceful "still waiting" response wins
// the boundary race without allowing an indefinite connection.
const httpTimeout = 90 * time.Second

const (
	maxConcurrentRequests      = 8
	maxInflightRequestBytes    = maxConcurrentRequests * maxFrameBytes
	maxRequestIDBytes          = 4_096
	cancellationForwardTimeout = 5 * time.Second
	requestTokenHeader         = "X-Emisar-MCP-Request-Token"
	cancelTokenHeader          = "X-Emisar-MCP-Cancel-Token"
	operationIDHeader          = "Emisar-Operation-Id"
)

// Streamable HTTP routing headers a client declaring protocol revision
// 2026-07-28 or later must mirror from the request body so gateways can route
// and meter without parsing JSON. The portal re-validates every one of them
// against the body and rejects a mismatch, so these are a copy of the frame's
// own bytes — never an independent claim the bridge invents.
const (
	protocolVersionHeader    = "MCP-Protocol-Version"
	methodHeader             = "Mcp-Method"
	nameHeader               = "Mcp-Name"
	protocolVersionMetaKey   = "io.modelcontextprotocol/protocolVersion"
	headerBase64SentinelHead = "=?base64?"
	headerBase64SentinelTail = "?="
)

// maxResponseBytes caps one portal response at the MCP API's complete semantic
// response budget plus encoding headroom. Timeouts bound time, not bytes.
const maxResponseBytes = 512 << 10

// maxFrameBytes matches the portal's MCP request-body boundary. The largest
// fixed tool input is 56 KiB encoded, leaving deliberate envelope headroom.
const maxFrameBytes = 128 << 10

// Self-reported MCP client metadata: an operator-configured key/value map
// (EMISAR_CLIENT_METADATA, a JSON object) the bridge validates once at startup
// and forwards on every request so the portal can snapshot it onto MCP action
// runs for audit/SIEM correlation with the operator's own MDM/EDR/inventory. It
// is UNTRUSTED, self-reported enrichment — never an authorization, posture, or
// approval input — so the portal independently re-validates these same limits at
// its boundary (a direct HTTP caller or a modified bridge can send anything).
const (
	clientMetadataHeader   = "Emisar-Client-Metadata"
	maxClientMetadataKeys  = 10
	maxClientMetadataKey   = 128
	maxClientMetadataValue = 512
)

// newHTTPClient builds the bridge's HTTP client: a hard request timeout plus a
// redirect refusal — the RPC endpoint never legitimately redirects, and
// following a 3xx would chase the Bearer API key to an attacker-chosen host.
func newHTTPClient() *http.Client {
	// The default transport keeps only 2 idle connections per host, so an
	// 8-way burst over HTTP/1.1 re-pays TCP+TLS for the rest on the next
	// burst. Match the pool to the bridge's own concurrency cap; an h2
	// endpoint multiplexes one connection regardless.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = maxConcurrentRequests
	return &http.Client{
		Transport:     transport,
		Timeout:       httpTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// Version is the build version, stamped by `-ldflags "-X main.Version=..."`
// from the release pipeline; "dev" when built locally.
var Version = "dev"

const helpText = `emisar-mcp - MCP bridge and direct CLI for emisar

DESCRIPTION
  Run a command from a terminal, script, or LLM. Human-readable output is the
  default. Add --json for the exact MCP structuredContent object and stable
  script output. Pass '-' instead of JSON to read one object from stdin.

  With no command, emisar-mcp speaks MCP over stdin and stdout for an MCP
  client. Both modes use the same server-owned tools, policy, approvals, and
  audit controls.

COMMANDS
  FLEET
    emisar-mcp list_runners [JSON | -]
      List runners, connectivity, groups, packs, issues, and exact refs.

    emisar-mcp list_packs [JSON | -]
      List trusted packs, availability, action counts, issues, and exact refs.

  ACTIONS
    emisar-mcp find_actions [TEXT | JSON | -]
      Search executable actions. Plain text works for the common case.

    emisar-mcp get_action [JSON | -]
      Inspect one action and its input contract.

    emisar-mcp run_action [JSON | -]
      Dispatch an action. Human mode waits for the result.

    emisar-mcp get_operation [JSON | -]
      Recover a request by operation ID before retrying a mutation.

    emisar-mcp recent_runs [JSON | -]
      List recent action runs and their status.

  RUNBOOKS
    emisar-mcp list_runbooks [JSON | -]
    emisar-mcp get_runbook [JSON | -]
    emisar-mcp execute_runbook [JSON | -]
    emisar-mcp create_runbook_draft [JSON | -]
    emisar-mcp update_runbook_draft [JSON | -]
      List, inspect, execute, and draft governed runbooks.
      Human execute_runbook waits for completion and prints action output.

  CONTINUATIONS
    emisar-mcp wait_for_run [JSON | -]
      Observe one run or runbook execution without repeating the mutation.

  ACCOUNTS AND AUTH
    emisar-mcp auth [login [URL]]
      Open the browser, choose an account, and authenticate this CLI. URL
      defaults to the current account, or https://emisar.dev the first time.

    emisar-mcp auth status [URL]
      Show the current or --account credential without printing its key. URL
      optionally requires an exact endpoint match.

    emisar-mcp accounts list
      List locally authenticated accounts. A star marks the current account.

    emisar-mcp accounts use <slug-or-id>
      Make one stored account current for later commands.

    emisar-mcp connect [--all | --client <id>]
      Detect the LLM clients installed for you, authenticate this CLI, and
      write each client's own configuration from one browser approval.

    emisar-mcp disconnect [--all | --client <id>]
      Remove the emisar entry from connected clients. Add --forget to also
      delete every stored account and this bridge's rotation state.

  MCP CLIENT AND DISCOVERY
    emisar-mcp
      Speak MCP over stdin and stdout for an MCP-aware client.

    emisar-mcp list_tools
      List live tools by category.

    emisar-mcp help <tool>
      Show live arguments. '<tool> --help' works for non-conflicting names.

    emisar-mcp <tool> [JSON | -]
      Call any exact tool name. Omit JSON when the tool accepts {}.

    emisar-mcp -- <tool> [JSON | -]
      Call a tool whose name conflicts with a local command or starts with '-'.

  SHARED COMMAND OPTIONS
    --account <slug-or-id>
      Use one stored account for auth status, discovery, or a tool call without
      changing the current account.

    --json
      Print exact JSON for accounts list, discovery, help, or a tool call.
      Put it last when calling a tool.

OUTPUT AND EXIT STATUS
  0  Success. Commands write readable text unless --json is present. In JSON
     mode, tool calls write the exact structuredContent object; list_tools and
     help write exact server-owned descriptors.

  1  Tool, MCP, and tool-call transport/response errors use the selected output
     format on stdout. In JSON mode, a call that may have reached the server
     includes data.operation_id; a call rejected before transmission omits it.
     Recover a mutation with get_operation before retrying it. A safe local
     diagnostic may also appear on stderr. Configuration and list/help failures
     write diagnostics to stderr.

     Human run_action also exits 1 for every terminal status except success.
     Human execute_runbook exits 1 when the execution is halted or cancelled.

  2  Invalid command or input. The diagnostic is on stderr.

  130  Ctrl-C stopped human-mode waiting. The action or runbook was not
       cancelled; stderr shows the get_operation recovery command.

  Direct-command errors explain what failed and what to do next. Color is used
  only in a terminal. Set NO_COLOR to disable it. Redirected and piped output
  never contains color codes.

ENVIRONMENT
  EMISAR_URL (required for stdio; optional for commands)
    Control-plane HTTP(S) origin. Do not include a path, credentials, query,
    or fragment. Example: https://emisar.dev. When both authentication env
    vars are absent, direct commands use the current stored account credential.

  EMISAR_API_KEY (required for stdio; optional for commands)
    Operator API key. Example: emk-... Both authentication env vars must be set
    together; an explicit pair overrides the current stored account credential.
    Do not combine an explicit pair with --account.

  EMISAR_CLIENT (optional)
    Audit-log label for this client, such as claude-code, cursor, codex, or
    grok. Defaults to "emisar-mcp-cli" for commands and "unknown" for stdio.

  EMISAR_CLIENT_METADATA (optional)
    Self-reported client metadata as a JSON object whose values are strings or
    numbers. Example: {"asset_tag":"LT-4417","device_id":"laptop-7"}
    Emisar snapshots it onto MCP action runs for audit and SIEM correlation.
    Maximum 10 keys; keys are limited to 128 characters and values to 512.
    This data is untrusted and is never used for authorization, posture, or
    approval. Invalid metadata is a startup error.

  EMISAR_ALLOW_INSECURE (optional)
    Set to 1 only for cleartext HTTP to a non-loopback development endpoint.
    Loopback HTTP works without it. Production should use HTTPS.

  EMISAR_SIGNING_KEY (optional)
    Ed25519 or ECDSA P-256 private key, as base64 of its PKCS#8 DER on one
    line. Set it with EMISAR_SIGNING_CERT to sign run_action intent for
    signature-enforcing runners. Create a pair with 'emisar signing new-cert'
    or 'emisar signing init', or issue one from your own PKI. Keep it secret
    and never put it on the control plane.

  EMISAR_SIGNING_CERT (optional)
    The X.509 certificate chain for EMISAR_SIGNING_KEY, as base64 of its PEM
    text on one line (leaf first, optional intermediate after). The bridge
    carries it with each signature; the runner verifies its trust, profile,
    scope, and validity.

CLIENT SETUP
  Install the bridge:
    curl -fsSL https://emisar.dev/install-mcp.sh | sudo bash

  An interactive install runs 'emisar-mcp connect' for you: it authenticates
  direct CLI commands and configures the supported local clients you pick, each
  with its own key, from one browser approval.

  Connect a client you install later, without reinstalling the bridge:
    emisar-mcp connect

  Manual client setup:
    https://emisar.dev/docs/connect-a-cli-client

KEY ROTATION
  emisar-mcp replaces expiring emk- keys automatically. It saves the new key
  before using it, so a restart cannot lose the working credential.

  If a direct command stops authenticating, run 'emisar-mcp auth' again and
  choose that account. If an MCP client stops authenticating, reconnect it from
  https://emisar.dev/app/agents/connect. Reconnecting does not revoke old keys;
  revoke connected keys in LLM agents.

FLAGS
  -h, --help
    Print this help and exit.

  -v, --version
    Print the version and exit.

PROTOCOL
  With no command, the bridge speaks line-delimited JSON-RPC 2.0 on stdin and
  stdout. CLI commands use the same HTTPS endpoint, credentials, signing,
  policy, approval, and audit path.
`

func main() {
	if code := runProgramMode(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, readerIsTerminal(os.Stdin)); code != 0 {
		os.Exit(code)
	}
}

// helpOrVersion answers -h/--help/-v/--version when it is the sole argument.
// Checked twice on purpose — before account parsing (bare `emisar-mcp --help`)
// and after (`emisar-mcp --account x --help`); the body lives once.
func helpOrVersion(args []string, stdout io.Writer) (int, bool) {
	if len(args) != 1 {
		return 0, false
	}
	switch args[0] {
	case "-h", "--help", "help":
		fmt.Fprint(stdout, helpText)
		return 0, true
	case "-v", "--version":
		fmt.Fprintf(stdout, "%s %s\n", bridgeName, Version)
		return 0, true
	}
	return 0, false
}

func runProgramMode(args []string, stdin io.Reader, stdout, stderr io.Writer, interactive bool) int {
	if len(args) == 0 && interactive {
		fmt.Fprint(stdout, helpText)
		return 0
	}
	if code, handled := helpOrVersion(args, stdout); handled {
		return code
	}
	account := ""
	if len(args) > 0 {
		var err error
		account, args, err = parseCLIAccount(args)
		if err != nil {
			return cliUsageError(stderr, err.Error())
		}
		if len(args) == 0 {
			return cliUsageError(stderr, "usage: emisar-mcp [--account <slug-or-id>] <command>")
		}
	}
	if code, handled := helpOrVersion(args, stdout); handled {
		return code
	}
	if len(args) > 0 && args[0] == "auth" {
		return runAuthCommand(account, args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "accounts" {
		if account != "" {
			return cliUsageError(stderr, "--account cannot be used with the accounts command")
		}
		return runAccountsCommand(args[1:], stdout, stderr)
	}
	if len(args) > 0 && (args[0] == "connect" || args[0] == "disconnect") {
		if account != "" {
			return cliUsageError(stderr, "--account cannot be used with the "+args[0]+" command")
		}
		if args[0] == "connect" {
			return runConnectCommand(args[1:], stdin, stdout, stderr)
		}
		return runDisconnectCommand(args[1:], stdin, stdout, stderr)
	}
	if len(args) > 0 && strings.HasPrefix(args[0], "-") && args[0] != "--" {
		return cliInputError(
			stderr,
			fmt.Sprintf("Unknown option %q", displayCLIOption(args[0])),
			"Run `emisar-mcp --help` to see available commands and options.",
		)
	}
	if err := validateCLIInvocation(args); err != nil {
		return cliUsageError(stderr, err.Error())
	}

	defaultClient := "unknown"
	if len(args) > 0 {
		defaultClient = "emisar-mcp-cli"
	}
	b, err := newBridgeFromEnv(defaultClient, len(args) > 0, account, stderr)
	if err != nil {
		if len(args) > 0 {
			return cliConfigurationFailure(stderr, err, account)
		}
		fmt.Fprintf(stderr, "%s: %v\n", bridgeName, err)
		return 1
	}

	if len(args) > 0 {
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		return b.runCLIContext(ctx, args, stdin, stdout, stderr)
	}
	if err := b.serve(stdin, stdout); err != nil && !errors.Is(err, io.EOF) {
		fmt.Fprintf(stderr, "%s: serve: %v\n", bridgeName, err)
		return 1
	}
	return 0
}

func readerIsTerminal(reader io.Reader) bool {
	file, ok := reader.(*os.File)
	return ok && fileIsTerminal(file)
}

func parseCLIAccount(args []string) (string, []string, error) {
	account := ""
	if len(args) > 0 && args[0] == "--account" {
		if len(args) < 2 || args[1] == "" || strings.HasPrefix(args[1], "-") {
			return "", nil, errors.New("usage: emisar-mcp --account <slug-or-id> <command>")
		}
		account = args[1]
		args = args[2:]
	}
	if account != "" && !validAccountSelector(account) {
		return "", nil, errors.New("account must be an exact slug or account ID")
	}
	return account, args, nil
}

func newBridgeFromEnv(defaultClient string, allowStoredCLI bool, account string, diagnostics io.Writer) (*bridge, error) {
	rawBase, urlSet := os.LookupEnv("EMISAR_URL")
	// A key pasted into a client config often carries a trailing newline or
	// space. Untrimmed it rides into the Authorization header, which the portal
	// rejects on every request — a permanent failure with no clue why.
	rawAPIKey, keySet := os.LookupEnv("EMISAR_API_KEY")
	apiKey := strings.TrimSpace(rawAPIKey)
	if account != "" && (urlSet || keySet) {
		return nil, errors.New("--account selects a stored credential and cannot be combined with EMISAR_URL or EMISAR_API_KEY")
	}

	var credentialStore *credentialStore
	usesStoredCLIAccount := false
	if !urlSet && !keySet && allowStoredCLI {
		store, state, err := loadCLICredential(account)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("no stored CLI credential for this account; %s or set both EMISAR_URL and EMISAR_API_KEY (try --help)", accountAuthHint(account))
			}
			return nil, fmt.Errorf("stored CLI credential: %w", err)
		}
		rawBase = state.EndpointOrigin
		apiKey = state.Current
		urlSet = true
		keySet = true
		credentialStore = store
		usesStoredCLIAccount = true
	}

	// Never fill one authentication variable from stored state. A partial env
	// override is almost certainly an endpoint/key mismatch and must fail closed.
	switch {
	case !urlSet && !keySet:
		return nil, errors.New("EMISAR_URL and EMISAR_API_KEY must both be set (try --help)")
	case !urlSet || rawBase == "":
		return nil, errors.New("EMISAR_URL must be set (try --help)")
	case !keySet || apiKey == "":
		return nil, errors.New("EMISAR_API_KEY must be set (try --help)")
	}

	// Fail closed on a cleartext URL to a non-loopback host: an http:// base
	// ships the Bearer API key (and every request) in plaintext, inviting
	// credential theft and MITM. Mirror the runner's cloud.allow_insecure
	// opt-in so a localhost dev endpoint still works.
	base, err := parseEndpoint(rawBase, allowInsecureEndpoints())
	if err != nil {
		return nil, err
	}

	// Optional bridge-attested dispatch: when a signing key is configured, the
	// bridge signs only run_action intent so an enforcing runner will run it. The
	// private key never leaves this process.
	sign, err := newSigner(os.Getenv("EMISAR_SIGNING_KEY"), os.Getenv("EMISAR_SIGNING_CERT"))
	if err != nil {
		return nil, err
	}
	// Drop the key from the environment once it is parsed: it is readable from
	// /proc/<pid>/environ for the life of the process, and every child the
	// client spawns inherits it. Go cannot wipe the string newSigner already
	// holds, so this narrows the exposure rather than removing it.
	_ = os.Unsetenv("EMISAR_SIGNING_KEY")

	// A durably promoted successor takes precedence over the bootstrap key in
	// the client's config, which may have expired since. A pending successor is
	// retried unchanged after a lost request, response, or process restart.
	if credentialStore == nil {
		var credsErr error
		credentialStore, credsErr = newRotationStore(base, apiKey)
		if credsErr != nil {
			if allowStoredCLI {
				writeCLIWarning(
					diagnostics,
					"Automatic key rotation is off",
					[]string{"The user configuration directory is unavailable: " + credsErr.Error()},
					"Tool commands still work. Fix the configuration directory before relying on automatic rotation.",
				)
			} else {
				fmt.Fprintf(diagnostics, "%s: no user config dir (%v); automatic key rotation disabled\n", bridgeName, credsErr)
			}
		}
	}

	// Self-reported client metadata: validated once at startup so a bad map is a
	// clear local error, never a partial snapshot on the control plane.
	clientMetadata, err := parseClientMetadata(os.Getenv("EMISAR_CLIENT_METADATA"))
	if err != nil {
		return nil, err
	}

	processNonce, err := newProcessNonce(rand.Reader)
	if err != nil {
		return nil, err
	}

	b := &bridge{
		endpoint:         base + "/api/mcp/rpc",
		portalOrigin:     base,
		apiKey:           apiKey,
		userAgent:        buildUserAgentWithDefault(defaultClient),
		client:           newHTTPClient(),
		processNonce:     processNonce,
		signer:           sign,
		clientMetadata:   clientMetadata,
		credentialStore:  credentialStore,
		storedCLIAccount: usesStoredCLIAccount,
		cliAccount:       account,
		directCLI:        allowStoredCLI,
		diagnostics:      diagnostics,
	}
	readOnlyCredentials, err := b.initializeCredentialState()
	if err != nil {
		return nil, fmt.Errorf("credential state: %w", err)
	}
	if readOnlyCredentials {
		if allowStoredCLI {
			writeCLIWarning(
				diagnostics,
				"Automatic key rotation is off",
				[]string{"The credential state is read-only."},
				"Tool commands still work. Fix the credential file permissions before relying on automatic rotation.",
			)
		} else {
			fmt.Fprintf(diagnostics, "%s: credential state is read-only; automatic key rotation disabled\n", bridgeName)
		}
	}
	return b, nil
}

type bridge struct {
	endpoint     string
	portalOrigin string
	apiKey       string
	userAgent    string
	client       *http.Client
	stateMu      sync.RWMutex
	// processNonce identifies this bridge process and namespaces request tokens
	// and operation ids. It never leaves those derived values:
	// the stateless portal does not issue or accept an MCP session id.
	processNonce string
	// signer, when set, creates the private action-attestation header for
	// run_action. Nil = signing disabled.
	signer *signer
	// clientMetadata is the operator's self-reported client metadata as canonical
	// JSON, validated once at startup and forwarded verbatim in every request's
	// clientMetadataHeader; "" when unset. It is untrusted correlation enrichment
	// the portal re-validates and snapshots onto MCP action runs — never an authz
	// input.
	clientMetadata string
	// protocolVersion is the version negotiated by initialize. Streamable HTTP
	// requires clients to echo it on subsequent requests, but not on initialize.
	protocolVersion    string
	credentialStore    *credentialStore
	credentialReadOnly bool
	storedCLIAccount   bool
	// cliAccount is the explicit, validated --account selector used for this
	// process. Human continuations preserve it so a copyable next command cannot
	// silently switch back to the current account.
	cliAccount string
	// cliSequence gives every direct command request a distinct request token.
	// A normal command makes one call; human mutation observation may make more.
	cliSequence uint64
	directCLI   bool
	pendingKey  string
	// credentialStamp fingerprints the last on-disk credential state this
	// process synced; a match lets the per-request refresh/proposal skip the
	// flock + read. Guarded by stateMu like the keys it shadows.
	credentialStamp credentialStateStamp
	// diagnostics receives operator-facing lines that stdout cannot carry —
	// stdout is the JSON-RPC transcript, and a synthetic error frame is
	// deliberately opaque. main() points it at stderr; nil keeps a bridge quiet.
	diagnostics io.Writer
	// authFailureOnce keeps the rejected-key hint to a single line: the
	// condition is permanent for the life of the process, so repeating it per
	// request would bury the client's log.
	authFailureOnce sync.Once
	// authRejected records that the control plane refused this credential, as
	// opposed to a transport failure. `connect` reads it to decide whether a
	// stored account still authenticates: a blip must not force the operator
	// through a fresh browser approval, but a revoked key must.
	authRejected atomic.Bool
}

// diagnose writes one operator-facing line to stderr. It never carries a
// response body, a credential, or anything else the portal supplied.
func (b *bridge) diagnose(format string, args ...any) {
	if b.diagnostics == nil {
		return
	}
	fmt.Fprintf(b.diagnostics, "emisar-mcp: "+format+"\n", args...)
}

// serve has one scheduling goroutine and one stdout owner. HTTP work may finish
// out of order, while frames and goroutines remain bounded. Cancellation is
// handled before ordinary admission so a saturated bridge can still release a
// long-running request.
func (b *bridge) serve(r io.Reader, w io.Writer) error {
	frames := make(chan frameRead, 1)
	results := make(chan forwardResult, maxConcurrentRequests)
	cancelResults := make(chan struct{}, maxConcurrentRequests)
	readerDone := make(chan struct{})
	defer close(readerDone)

	go readFrames(r, frames, readerDone)

	state := serveState{
		inflight:      make(map[string]*inflightRequest, maxConcurrentRequests),
		requestTokens: make(map[string]string, maxConcurrentRequests),
	}

	for frames != nil || len(state.inflight) > 0 || state.cancelForwards > 0 {
		select {
		case frame := <-frames:
			if err := b.handleFrame(frame, w, &state, results, cancelResults); err != nil {
				cancelInflight(state.inflight)
				return err
			}
			if frame.err != nil {
				if !errors.Is(frame.err, io.EOF) {
					cancelInflight(state.inflight)
					return frame.err
				}
				frames = nil
			}

		case result := <-results:
			request := state.completeRequest(result.token)
			if request == nil {
				continue
			}
			if request.cancelled {
				continue
			}
			if err := b.writeForwardResult(
				w,
				request.meta,
				request.operationID,
				result.response,
				result.err,
			); err != nil {
				cancelInflight(state.inflight)
				return err
			}

		case <-cancelResults:
			state.cancelForwards--
		}
	}

	return nil
}

type frameRead struct {
	line     []byte
	oversize bool
	err      error
}

type inflightRequest struct {
	meta                  requestMeta
	idKey                 string
	operationID           string
	frameBytes            int
	protocolVersion       string
	cancel                context.CancelFunc
	cancelled             bool
	cancellationForwarded bool
}

type forwardResult struct {
	token    string
	response []byte
	err      error
}

type requestHeaders struct {
	apiKey          string
	protocolVersion string
	requestToken    string
	cancelToken     string
	operationID     string
}

type serveState struct {
	inflight       map[string]*inflightRequest
	inflightBytes  int
	requestTokens  map[string]string
	sequence       uint64
	cancelForwards int
}

func (s *serveState) completeRequest(token string) *inflightRequest {
	request := s.inflight[token]
	if request == nil {
		return nil
	}
	delete(s.inflight, token)
	s.inflightBytes -= request.frameBytes
	if request.idKey != "" && s.requestTokens[request.idKey] == token {
		delete(s.requestTokens, request.idKey)
	}
	return request
}

func readFrames(r io.Reader, frames chan<- frameRead, done <-chan struct{}) {
	reader := bufio.NewReaderSize(r, 64*1024)
	for {
		line, oversize, err := readFrameLine(reader)
		if firstJSONByte(line) == 0 {
			line = nil
		}
		frame := frameRead{line: line, oversize: oversize, err: err}
		select {
		case frames <- frame:
		case <-done:
			return
		}
		if err != nil {
			return
		}
	}
}

func (b *bridge) handleFrame(
	frame frameRead,
	w io.Writer,
	state *serveState,
	results chan<- forwardResult,
	cancelResults chan<- struct{},
) error {
	if frame.oversize {
		b.diagnose("dropping a request frame over %d bytes", maxFrameBytes)
		return writeFrame(w, rpcErrorFrame(requestMeta{}, -32600, "request frame too large"))
	}
	if len(frame.line) == 0 {
		return nil
	}
	if err := validateStrictJSON(frame.line); err != nil {
		return writeFrame(w, rpcErrorFrame(requestMeta{}, -32700, "parse error"))
	}

	meta := parseRequestMeta(frame.line)
	if !meta.valid {
		return writeFrame(w, rpcErrorFrame(meta, -32600, "invalid request"))
	}
	if meta.notification() && meta.method == "notifications/cancelled" {
		b.handleCancellation(frame.line, meta, state, cancelResults)
		return nil
	}
	if meta.notification() && !strings.HasPrefix(meta.method, "notifications/") {
		return nil
	}

	idKey := requestIDKey(meta)
	if idKey != "" {
		if _, inFlight := state.requestTokens[idKey]; inFlight {
			return writeFrame(w, rpcErrorFrame(meta, -32600, "request id is already in flight"))
		}
	}
	if len(state.inflight) >= maxConcurrentRequests {
		if meta.notification() {
			return nil
		}
		return writeFrame(w, rpcErrorFrame(meta, -32000, "too many in-flight requests"))
	}
	if len(frame.line) > maxInflightRequestBytes-state.inflightBytes {
		if meta.notification() {
			return nil
		}
		return writeFrame(w, rpcErrorFrame(meta, -32000, "in-flight request byte limit reached"))
	}

	state.sequence++
	token := b.requestToken(state.sequence)
	ctx, cancel := context.WithCancel(context.Background())
	apiKey, protocolVersion := b.transportState()
	operationID := toolCallOperationID(meta, token)
	state.inflight[token] = &inflightRequest{
		meta:            meta,
		idKey:           idKey,
		operationID:     operationID,
		frameBytes:      len(frame.line),
		protocolVersion: protocolVersion,
		cancel:          cancel,
	}
	state.inflightBytes += len(frame.line)
	if idKey != "" {
		state.requestTokens[idKey] = token
	}

	headers := requestHeaders{
		apiKey: apiKey, protocolVersion: protocolVersion, operationID: operationID,
	}
	if idKey != "" {
		headers.requestToken = token
	}
	go func() {
		response, err := b.forwardRequestContext(ctx, frame.line, meta, headers)
		cancel()
		results <- forwardResult{token: token, response: response, err: err}
	}()
	return nil
}

func (b *bridge) handleCancellation(
	frame []byte,
	meta requestMeta,
	state *serveState,
	cancelResults chan<- struct{},
) {
	idKey := cancellationTargetKey(frame)
	token := state.requestTokens[idKey]
	request := state.inflight[token]
	if request == nil || request.meta.method == "initialize" {
		return
	}

	request.cancelled = true
	request.cancel()
	if request.cancellationForwarded {
		return
	}
	// Cancellation deliberately bypasses admission so a saturated bridge can
	// still release a wait — but the FORWARD is an outbound POST, and it was
	// uncapped. A client that opened and cancelled in a loop drove one live
	// goroutine and socket per cycle, each held for the forward timeout,
	// bursting the portal's limiter. The local cancel above has already stopped
	// observation, which is the part that must never be delayed; dropping the
	// courtesy notification under pressure costs nothing.
	if state.cancelForwards >= maxConcurrentRequests {
		return
	}
	request.cancellationForwarded = true
	state.cancelForwards++

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), cancellationForwardTimeout)
		defer cancel()
		_, _ = b.forwardRequestContext(ctx, frame, meta, requestHeaders{
			protocolVersion: request.protocolVersion,
			cancelToken:     token,
		})
		cancelResults <- struct{}{}
	}()
}

func requestIDKey(meta requestMeta) string {
	canonical, ok := canonicalRequestID(meta)
	if !ok {
		return ""
	}
	return digestRequestID(canonical)
}

func canonicalRequestID(meta requestMeta) (string, bool) {
	if !meta.valid || !meta.hasID {
		return "", false
	}
	switch meta.idKind {
	case 's':
		var id string
		if json.Unmarshal(meta.id, &id) == nil {
			return "s:" + id, true
		}
	case 'n':
		if id, ok := new(big.Rat).SetString(string(meta.id)); ok {
			return "n:" + id.RatString(), true
		}
	}
	return "", false
}

func digestRequestID(canonical string) string {
	digest := sha256.Sum256([]byte(canonical))
	return string(digest[:])
}

func (b *bridge) requestToken(sequence uint64) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte("emisar-mcp-request-v1"))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(b.processNonce))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write(strconv.AppendUint(nil, sequence, 10))
	return hex.EncodeToString(digest.Sum(nil))
}

func cancellationTargetKey(frame []byte) string {
	if validateStrictJSON(frame) != nil {
		return ""
	}
	var notification map[string]json.RawMessage
	if json.Unmarshal(frame, &notification) != nil {
		return ""
	}
	var params map[string]json.RawMessage
	if json.Unmarshal(notification["params"], &params) != nil {
		return ""
	}
	id := bytes.TrimSpace(params["requestId"])
	return requestIDKey(requestMeta{id: id, idKind: jsonRPCIDKind(id), hasID: true, valid: true})
}

func (b *bridge) writeForwardResult(
	w io.Writer,
	meta requestMeta,
	operationID string,
	response []byte,
	err error,
) error {
	if err != nil {
		// The client frame stays opaque, so without this the operator sees a
		// bare -32603 and nothing anywhere explains it — and a failed
		// notification produces no frame at all. Only a locally generated
		// transport error is echoed; a portal response never is.
		if localTransportError(err) || bridgeProducedError(err) {
			b.diagnose("%v", err)
		}
		if meta.notification() {
			return nil
		}
		// Nothing was transmitted, so there is no operation to recover.
		if bridgeProducedError(err) {
			return writeFrame(w, rpcErrorFrame(meta, -32603, "emisar bridge could not send this request"))
		}
		return writeFrame(w, transportErrorFrame(meta, operationID))
	}
	if len(response) == 0 {
		return nil
	}
	return writeFrame(w, response)
}

// bridgeLocalError marks a failure this process produced BEFORE anything was
// sent — a signing refusal, or credential state it could not read or write.
// It matters because the operation id in a transport error tells the model the
// mutation may have reached Emisar and should be recovered; for these it
// provably never left, so reporting one sends the model chasing an operation
// that does not exist while the real cause is nowhere on stderr.
type bridgeLocalError struct{ err error }

func (e *bridgeLocalError) Error() string { return e.err.Error() }
func (e *bridgeLocalError) Unwrap() error { return e.err }

func localBridge(err error) error { return &bridgeLocalError{err: err} }

func bridgeProducedError(err error) bool {
	var local *bridgeLocalError
	return errors.As(err, &local)
}

// localTransportError reports whether err was produced by this process's own
// HTTP stack — a refused dial, a DNS failure, a timeout, a rejected header
// value, or a TLS handshake failure, all of which http.Client returns wrapped
// in *url.Error. Those are safe to print: they describe the local attempt, not
// the portal's answer. Everything else — a response the bridge refused to
// forward — stays unprinted, so no upstream body can reach a stream.
func localTransportError(err error) bool {
	var urlErr *url.Error
	var opErr *net.OpError
	return errors.As(err, &urlErr) || errors.As(err, &opErr)
}

func cancelInflight(inflight map[string]*inflightRequest) {
	for _, request := range inflight {
		request.cancel()
	}
}

type requestMeta struct {
	id     json.RawMessage
	idKind byte
	hasID  bool
	valid  bool
	method string
	// protocolVersion is the revision a modern client declares per request in
	// params._meta. Empty for a legacy frame, which negotiates once at
	// initialize instead.
	protocolVersion string
	// routingName is the params.name / params.uri value the modern transport
	// mirrors into Mcp-Name. Transport routing metadata, not tool
	// interpretation: the bridge copies these bytes and the portal validates
	// them back against the same body.
	routingName string
}

// parseRequestMeta reads only the transport metadata the bridge must own. The
// portal remains responsible for method and parameter validation.
func parseRequestMeta(frame []byte) requestMeta {
	var envelope map[string]json.RawMessage
	if !utf8.Valid(frame) || json.Unmarshal(frame, &envelope) != nil || envelope == nil {
		return requestMeta{}
	}

	meta := requestMeta{}
	validID := true
	rawID, ok := envelope["id"]
	if ok {
		meta.hasID = true
		meta.id = bytes.TrimSpace(rawID)
		meta.idKind = jsonRPCIDKind(meta.id)
		validID = meta.idKind != 0
	}

	var version string
	if json.Unmarshal(envelope["jsonrpc"], &version) != nil || version != "2.0" {
		return meta
	}
	rawMethod := bytes.TrimSpace(envelope["method"])
	if len(rawMethod) < 2 || rawMethod[0] != '"' || json.Unmarshal(rawMethod, &meta.method) != nil {
		return meta
	}

	meta.valid = validID
	meta.protocolVersion, meta.routingName = parseRoutingMetadata(envelope["params"], meta.method)
	return meta
}

// parseRoutingMetadata reads the per-request protocol declaration and the
// Mcp-Name source value that revision 2026-07-28 mirrors into HTTP headers.
// Only the three methods the spec names carry Mcp-Name; params that are absent,
// non-object, or malformed simply yield no routing metadata, leaving the frame
// to the portal's own validation.
func parseRoutingMetadata(params json.RawMessage, method string) (protocolVersion, routingName string) {
	if len(bytes.TrimSpace(params)) == 0 {
		return "", ""
	}
	var fields struct {
		Meta map[string]json.RawMessage `json:"_meta"`
		Name string                     `json:"name"`
		URI  string                     `json:"uri"`
	}
	if json.Unmarshal(params, &fields) != nil {
		return "", ""
	}
	if raw, ok := fields.Meta[protocolVersionMetaKey]; ok {
		_ = json.Unmarshal(raw, &protocolVersion)
	}
	switch method {
	case "tools/call", "prompts/get":
		routingName = fields.Name
	case "resources/read":
		routingName = fields.URI
	}
	return protocolVersion, routingName
}

func jsonRPCIDKind(id []byte) byte {
	var value string
	if len(id) >= 2 && id[0] == '"' && json.Unmarshal(id, &value) == nil && len(value) <= maxRequestIDBytes {
		return 's'
	}
	if len(id) <= maxRequestIDBytes && validJSONInteger(id) {
		return 'n'
	}
	return 0
}

func validJSONInteger(value []byte) bool {
	if len(value) == 0 {
		return false
	}
	if value[0] == '-' {
		value = value[1:]
		if len(value) == 0 {
			return false
		}
	}
	if value[0] == '0' {
		return len(value) == 1
	}
	if value[0] < '1' || value[0] > '9' {
		return false
	}
	for _, digit := range value[1:] {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func (m requestMeta) notification() bool {
	return m.valid && !m.hasID
}

func (m requestMeta) responseID() json.RawMessage {
	if m.hasID && m.idKind != 0 {
		return m.id
	}
	return json.RawMessage("null")
}

func rpcErrorFrame(meta requestMeta, code int, message string) []byte {
	return rpcErrorFrameWithData(meta, code, message, nil)
}

type transportErrorData struct {
	OperationID string `json:"operation_id"`
}

func transportErrorFrame(meta requestMeta, operationID string) []byte {
	if operationID == "" {
		return rpcErrorFrame(meta, -32603, "upstream transport error")
	}

	data := &transportErrorData{OperationID: operationID}
	return rpcErrorFrameWithData(meta, -32603, "upstream transport error", data)
}

func rpcErrorFrameWithData(
	meta requestMeta,
	code int,
	message string,
	data *transportErrorData,
) []byte {
	frame, err := json.Marshal(struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Error   struct {
			Code    int                 `json:"code"`
			Message string              `json:"message"`
			Data    *transportErrorData `json:"data,omitempty"`
		} `json:"error"`
	}{
		JSONRPC: "2.0",
		ID:      meta.responseID(),
		Error: struct {
			Code    int                 `json:"code"`
			Message string              `json:"message"`
			Data    *transportErrorData `json:"data,omitempty"`
		}{Code: code, Message: message, Data: data},
	})
	if err != nil {
		panic("marshal fixed JSON-RPC error: " + err.Error())
	}
	return frame
}

func writeFrame(w io.Writer, frame []byte) error {
	trimmed := bytes.TrimRight(frame, "\r\n")
	// One frame is one line. The strict parser accepts a newline BETWEEN JSON
	// tokens, so a pretty-printed portal response validated fine and then
	// arrived at the client as several malformed lines — the request id never
	// correlated and the session desynced. Runner output can never do this (a
	// control character inside a JSON string is rejected, and an escaped \n
	// stays one line); only the encoder's own whitespace can, which is exactly
	// what a reformatting proxy in front of the portal produces.
	// Collapse it rather than failing. The frame has already passed a strict
	// parse, so a raw newline here can only be insignificant space BETWEEN
	// tokens — a control character inside a JSON string is rejected, and an
	// escaped \n stays one line — which makes a space semantically identical.
	// Refusing instead returned an error that unwound through serve into
	// fatalln, so one reformatted upstream response killed the process and
	// every concurrent in-flight request with it, including dispatches that had
	// already reached the portal. Locally built frames never contain newlines,
	// so this is a no-op for them.
	if bytes.ContainsAny(trimmed, "\n\r") {
		trimmed = bytes.ReplaceAll(trimmed, []byte("\n"), []byte(" "))
		trimmed = bytes.ReplaceAll(trimmed, []byte("\r"), []byte(" "))
	}
	line := make([]byte, 0, len(trimmed)+1)
	line = append(line, trimmed...)
	line = append(line, '\n')
	n, err := w.Write(line)
	if err != nil {
		return err
	}
	if n != len(line) {
		return io.ErrShortWrite
	}
	return nil
}

// readFrameLine reads one newline-delimited frame from br, bounding the bytes it
// retains to maxFrameBytes. bufio.Reader.ReadString would accumulate an entire
// newline-free stream into one slice before any length check — a hostile or
// malfunctioning client could OOM the bridge that way (the symmetric hole the
// response cap closes on the HTTP side). Instead we read in buffer-sized chunks;
// once a body crosses the cap we drop what we've accumulated and keep draining
// the rest of the (over-long) line to its terminating newline so the next frame
// still aligns, returning oversize=true. The line delimiter is not part of the
// JSON body budget. Peak retained bytes stay at maxFrameBytes plus CRLF.
func readFrameLine(br *bufio.Reader) (line []byte, oversize bool, err error) {
	for {
		chunk, e := br.ReadSlice('\n')
		if !oversize {
			if len(line)+len(chunk) > maxFrameBytes+2 {
				oversize = true
				line = nil // reject the frame; release what we'd buffered
			} else {
				line = append(line, chunk...)
			}
		}
		if e == bufio.ErrBufferFull {
			continue // line longer than br's buffer — keep draining it
		}
		if !oversize {
			line = trimFrameDelimiter(line)
			if len(line) > maxFrameBytes {
				line = nil
				oversize = true
			}
		}
		return line, oversize, e
	}
}

func trimFrameDelimiter(line []byte) []byte {
	if len(line) == 0 || line[len(line)-1] != '\n' {
		return line
	}
	line = line[:len(line)-1]
	if len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	return line
}

func (b *bridge) forwardRequestContext(
	ctx context.Context,
	frame []byte,
	meta requestMeta,
	headers requestHeaders,
) ([]byte, error) {
	if !meta.valid {
		return nil, errors.New("invalid JSON-RPC request envelope")
	}
	ctx, cancel := context.WithTimeout(ctx, httpTimeout)
	defer cancel()
	if err := b.refreshCredentialState(); err != nil {
		// A peer holding the cross-process lock past its timeout (or another
		// transient write-access denial) must not fail an otherwise-valid
		// request: skip this request's rotation refresh and proceed on the
		// current credential, the same way startup degrades to read-only reads.
		// withLock returns before mutating state, so the in-memory key is intact.
		if !isCredentialWriteDegradable(err) {
			return nil, localBridge(fmt.Errorf("refresh credential state: %w", err))
		}
	}

	operationID := headers.operationID
	if operationID == "" {
		operationID = toolCallOperationID(meta, headers.requestToken)
	}
	attestationValue := ""
	// Only a tools/call frame can carry run_action; meta.method decodes the
	// same envelope "method" bytes signFrame's exact parse would, so skipping
	// here can never disagree with it on a serve-validated frame.
	if b.signer != nil && meta.method == "tools/call" {
		var signErr error
		attestationValue, signErr = b.signer.signFrame(frame, operationID, b.portalOrigin)
		if signErr != nil {
			return nil, localBridge(fmt.Errorf("attest run_action: %w", signErr))
		}
	}
	rotationPrefix, rotationHash := "", ""
	if !meta.notification() {
		rotationPrefix, rotationHash = b.rotationProposal()
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.endpoint, bytes.NewReader(frame))
	if err != nil {
		return nil, err
	}
	apiKey, protocolVersion := headers.apiKey, headers.protocolVersion
	if b.credentialStore != nil || apiKey == "" || meta.method == "initialize" {
		apiKey, protocolVersion = b.transportState()
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	// Streamable HTTP clients advertise both response transports. The Emisar
	// endpoint deliberately returns one buffered JSON response, never SSE.
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)
	// A modern client declares its revision inside every frame and never sends
	// initialize, so there is no negotiated version to fall back on: mirror what
	// the frame itself declares. A legacy client keeps the version it negotiated.
	if !setModernRoutingHeaders(req.Header, meta) &&
		meta.method != "initialize" && protocolVersion != "" {
		req.Header.Set(protocolVersionHeader, protocolVersion)
	}
	if headers.requestToken != "" {
		req.Header.Set(requestTokenHeader, headers.requestToken)
	}
	if headers.cancelToken != "" {
		req.Header.Set(cancelTokenHeader, headers.cancelToken)
	}
	if rotationPrefix != "" {
		req.Header.Set(rotationPrefixHeader, rotationPrefix)
		req.Header.Set(rotationHashHeader, rotationHash)
	}
	if operationID != "" {
		req.Header.Set(operationIDHeader, operationID)
	}
	if attestationValue != "" {
		req.Header.Set(attestationHeader, attestationValue)
	}

	// Self-reported client metadata (untrusted correlation enrichment). Forwarded
	// verbatim on every request; the portal re-validates it and snapshots it onto
	// MCP action runs. Omitted entirely when unconfigured.
	if b.clientMetadata != "" {
		req.Header.Set(clientMetadataHeader, b.clientMetadata)
	}

	result, err := b.forwardAttempt(req, meta)
	if err != nil && operationID != "" && ctx.Err() == nil {
		result, err = b.forwardAttempt(cloneRequestWithBody(req, ctx, frame), meta)
	}
	if result.status == http.StatusUnauthorized {
		recoveryKey, recoveryErr := b.credentialRecoveryKey(apiKey)
		if recoveryErr != nil {
			return nil, localBridge(fmt.Errorf("recover credential state: %w", recoveryErr))
		}
		if recoveryKey != "" && recoveryKey != apiKey {
			retry := cloneRequestWithBody(req, ctx, frame)
			retry.Header.Set("Authorization", "Bearer "+recoveryKey)
			result, err = b.forwardAttempt(retry, meta)
			if err == nil && (result.status >= 200 && result.status < 500) &&
				result.status != http.StatusUnauthorized {
				// The portal already accepted this frame under the recovered key and
				// dispatched it. Discarding that successful response over a failed
				// persist would tell the model "could not be sent" and have it retry an
				// action that is already running. The successor is usable in memory and
				// the next process re-derives durable state, so a persist failure here
				// is a stderr warning, not a request failure.
				if adoptErr := b.adoptRecoveryKey(recoveryKey); adoptErr != nil {
					b.diagnose("recovered the account credential but could not persist it (the request succeeded): %v", adoptErr)
				}
			}
		}
	}
	// Still refused after any rotation successor was tried: the configured key
	// is the problem, and the client frame stays opaque on purpose. Say so once
	// on stderr, where an operator can act on it. The wire answer is unchanged.
	if result.status == http.StatusUnauthorized {
		b.authRejected.Store(true)
		b.authFailureOnce.Do(func() {
			if b.storedCLIAccount {
				if b.directCLI {
					writeCLIDiagnostic(b.diagnostics, cliDiagnostic{
						Kind:    cliDiagnosticError,
						Summary: "The account credential was rejected",
						Details: []string{"The control plane no longer accepts the stored credential for this account."},
						Next:    []string{"Run `emisar-mcp auth` and choose the account again."},
					})
					return
				}
				b.diagnose("the control plane rejected this account credential — " +
					"run 'emisar-mcp auth' and choose the account again")
				return
			}
			if b.directCLI {
				writeCLIDiagnostic(b.diagnostics, cliDiagnostic{
					Kind:    cliDiagnosticError,
					Summary: "The API key was rejected",
					Details: []string{"The control plane no longer accepts EMISAR_API_KEY."},
					Next: []string{
						"Check EMISAR_API_KEY, or create a new key at " + b.portalOrigin + "/app/agents.",
					},
				})
				return
			}
			b.diagnose("the control plane rejected this API key — "+
				"check EMISAR_API_KEY or mint a new one at %s/app/agents", b.portalOrigin)
		})
	}
	if err != nil {
		return nil, err
	}
	body := result.body

	if meta.method == "initialize" {
		version, hasResult, valid := responseProtocolVersion(body)
		if hasResult && !valid {
			return nil, errors.New("initialize response has an invalid protocol version")
		}
		if hasResult {
			b.setProtocolVersion(version)
		}
	}

	if !meta.notification() {
		b.acknowledgeRotation(result.header.Get(rotationAckHeader))
	}

	return body, nil
}

type portalResponse struct {
	status int
	header http.Header
	body   []byte
}

func (b *bridge) forwardAttempt(req *http.Request, meta requestMeta) (portalResponse, error) {
	resp, err := b.client.Do(req)
	if err != nil {
		return portalResponse{}, err
	}
	defer resp.Body.Close()

	result := portalResponse{status: resp.StatusCode, header: resp.Header.Clone()}
	if meta.notification() {
		if resp.StatusCode != http.StatusAccepted {
			return result, fmt.Errorf("control plane returned status %d for a notification", resp.StatusCode)
		}
		body, err := readCappedBody(resp.Body, maxResponseBytes)
		if err != nil {
			return result, err
		}
		if len(bytes.TrimSpace(body)) != 0 {
			return result, errors.New("control plane returned a body for a notification")
		}
		return result, nil
	}
	if resp.StatusCode == http.StatusAccepted {
		return result, errors.New("control plane returned notification status for a request")
	}
	if resp.StatusCode != http.StatusOK && (resp.StatusCode < 400 || resp.StatusCode >= 500) {
		return result, fmt.Errorf("unsupported control-plane response status %d", resp.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !strings.EqualFold(mediaType, "application/json") {
		return result, errors.New("control-plane response is not application/json")
	}
	body, err := readCappedBody(resp.Body, maxResponseBytes)
	if err != nil {
		return result, err
	}
	// validateStrictJSON inside validateRPCResponse begins with the UTF-8
	// scan, so a separate utf8.Valid pass here would read the body twice.
	if err := validateRPCResponse(meta, resp.StatusCode, body); err != nil {
		return result, err
	}
	result.body = body
	return result, nil
}

func cloneRequestWithBody(req *http.Request, ctx context.Context, frame []byte) *http.Request {
	retry := req.Clone(ctx)
	retry.Body = io.NopCloser(bytes.NewReader(frame))
	return retry
}

func (b *bridge) transportState() (apiKey, protocolVersion string) {
	b.stateMu.RLock()
	defer b.stateMu.RUnlock()
	return b.apiKey, b.protocolVersion
}

func (b *bridge) setProtocolVersion(version string) {
	b.stateMu.Lock()
	b.protocolVersion = version
	b.stateMu.Unlock()
}

func validateRPCResponse(meta requestMeta, status int, body []byte) error {
	if err := validateStrictJSON(body); err != nil {
		return errors.New("control-plane response is not strict JSON")
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil || envelope == nil {
		return errors.New("control-plane response is not a JSON-RPC object")
	}

	var version string
	if err := json.Unmarshal(envelope["jsonrpc"], &version); err != nil || version != "2.0" {
		return errors.New("control-plane response has an invalid jsonrpc version")
	}
	responseID, ok := envelope["id"]
	if !ok || !matchingJSONRPCID(meta.responseID(), responseID) {
		return errors.New("control-plane response id does not match request")
	}
	_, hasResult := envelope["result"]
	rawError, hasError := envelope["error"]
	if hasResult == hasError {
		return errors.New("control-plane response must contain exactly one of result or error")
	}
	if status >= 400 && !hasError {
		return errors.New("control-plane error status did not contain a JSON-RPC error")
	}
	if hasError && !validRPCError(rawError) {
		return errors.New("control-plane response has an invalid JSON-RPC error")
	}
	return nil
}

func matchingJSONRPCID(want, got json.RawMessage) bool {
	want = bytes.TrimSpace(want)
	got = bytes.TrimSpace(got)
	wantKind := jsonRPCIDKind(want)
	if wantKind == 0 || wantKind != jsonRPCIDKind(got) {
		return false
	}
	if wantKind == 's' {
		var wantString, gotString string
		return json.Unmarshal(want, &wantString) == nil &&
			json.Unmarshal(got, &gotString) == nil &&
			wantString == gotString
	}
	if wantKind == 'n' {
		wantNumber, wantOK := new(big.Rat).SetString(string(want))
		gotNumber, gotOK := new(big.Rat).SetString(string(got))
		return wantOK && gotOK && wantNumber.Cmp(gotNumber) == 0
	}
	return bytes.Equal(want, got)
}

func validRPCError(raw json.RawMessage) bool {
	var rpcError map[string]json.RawMessage
	if err := json.Unmarshal(raw, &rpcError); err != nil || rpcError == nil {
		return false
	}
	var message string
	if err := json.Unmarshal(rpcError["message"], &message); err != nil {
		return false
	}
	var code json.Number
	decoder := json.NewDecoder(bytes.NewReader(rpcError["code"]))
	decoder.UseNumber()
	if err := decoder.Decode(&code); err != nil {
		return false
	}
	_, err := code.Int64()
	return err == nil
}

// setModernRoutingHeaders mirrors a modern frame's own declaration into the
// Streamable HTTP routing headers, reporting whether it did. It stays silent
// for a legacy frame, and for a malformed declaration or a method that could
// not survive a header field value — the frame still carries those bytes in its
// body, so the portal answers with its own protocol error instead of the bridge
// inventing a header the body does not support.
func setModernRoutingHeaders(header http.Header, meta requestMeta) bool {
	if !validProtocolVersion(meta.protocolVersion) || !headerSafeValue(meta.method) {
		return false
	}
	header.Set(protocolVersionHeader, meta.protocolVersion)
	header.Set(methodHeader, meta.method)
	if meta.routingName != "" {
		header.Set(nameHeader, encodeHeaderValue(meta.routingName))
	}
	return true
}

// encodeHeaderValue renders a value for Mcp-Name. A value that is already safe
// as an HTTP field value rides through unchanged; anything else — non-ASCII,
// control characters, surrounding whitespace, or a literal that would itself
// read as the sentinel — is wrapped so the portal decodes exactly the bytes the
// body carries.
func encodeHeaderValue(value string) string {
	if headerSafeValue(value) && !strings.HasPrefix(value, headerBase64SentinelHead) {
		return value
	}
	encoded := base64.StdEncoding.EncodeToString([]byte(value))
	return headerBase64SentinelHead + encoded + headerBase64SentinelTail
}

// headerSafeValue reports whether a value can be sent verbatim: non-empty and
// entirely visible ASCII, which excludes the CR/LF a hostile frame would need
// to forge a second header.
func headerSafeValue(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < 0x21 || value[i] > 0x7E {
			return false
		}
	}
	return true
}

// validProtocolVersion accepts only the spec's exact `YYYY-MM-DD` revision
// shape. The bridge stays version-agnostic — any well-formed date mirrors
// through and the portal decides which revisions it serves.
func validProtocolVersion(version string) bool {
	if version == "" {
		return false
	}
	parsed, err := time.Parse("2006-01-02", version)
	return err == nil && parsed.Format("2006-01-02") == version
}

func responseProtocolVersion(body []byte) (version string, hasResult, valid bool) {
	var response map[string]json.RawMessage
	if json.Unmarshal(body, &response) != nil || response == nil {
		return "", false, false
	}
	resultRaw, hasResult := response["result"]
	if !hasResult {
		return "", false, true
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(resultRaw, &result) != nil || result == nil {
		return "", true, false
	}
	if err := json.Unmarshal(result["protocolVersion"], &version); err != nil {
		return "", true, false
	}
	if !validProtocolVersion(version) {
		return "", true, false
	}
	return version, true, true
}

// readCappedBody reads at most limit bytes from r, returning an error if the
// source has more — the portal response is untrusted (a hostile or MITM'd
// endpoint could stream unbounded bytes), and http.Client.Timeout bounds time,
// not size. Reading limit+1 lets a body of exactly limit through.
func readCappedBody(r io.Reader, limit int) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(body) > limit {
		return nil, fmt.Errorf("control-plane response exceeds %d bytes", limit)
	}
	return body, nil
}

// operationIDForToken derives a private operation identity from one admitted
// request token. JSON-RPC ids are only correlation values and may be reused
// after completion; transport retries retain the original token and operation.
func operationIDForToken(requestToken string) string {
	if requestToken == "" {
		return ""
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte("emisar-mcp-operation-v1"))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(requestToken))
	var operationBytes [16]byte
	copy(operationBytes[:], digest.Sum(nil))
	return "op_" + encodeCrockford128(operationBytes)
}

func toolCallOperationID(meta requestMeta, requestToken string) string {
	if !meta.valid || meta.notification() || meta.method != "tools/call" {
		return ""
	}
	return operationIDForToken(requestToken)
}

func encodeCrockford128(value [16]byte) string {
	const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	n := new(big.Int).SetBytes(value[:])
	encoded := make([]byte, 26)
	mask := big.NewInt(31)
	digit := new(big.Int)
	for i := len(encoded) - 1; i >= 0; i-- {
		encoded[i] = alphabet[digit.And(n, mask).Int64()]
		n.Rsh(n, 5)
	}
	return string(encoded)
}

// parseClientMetadata validates the operator's EMISAR_CLIENT_METADATA (a JSON
// object of string keys to string-or-number values) and returns the canonical
// JSON to forward in the clientMetadataHeader. It FAILS CLOSED: any malformed
// input, disallowed value type (array/object/bool/null), or exceeded limit is a
// startup error, never a partially-applied map. An empty/unset value — or an
// empty object — yields "" (no header). The limits mirror the portal's boundary
// check; both sides enforce them independently because the header is untrusted
// (a direct HTTP caller or a modified bridge can send anything).
func parseClientMetadata(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}

	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber() // keep numbers exact — no float rounding of an asset id
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA must be a JSON object: %w", err)
	}
	if m == nil {
		return "", errors.New("EMISAR_CLIENT_METADATA must be a non-null JSON object")
	}
	if err := ensureJSONEOF(dec); err != nil {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA must be a single JSON object: %w", err)
	}
	if len(m) > maxClientMetadataKeys {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA has %d keys, the maximum is %d", len(m), maxClientMetadataKeys)
	}

	clean := make(map[string]any, len(m))
	for key, val := range m {
		if utf8.RuneCountInString(key) > maxClientMetadataKey {
			return "", fmt.Errorf("EMISAR_CLIENT_METADATA key %q exceeds %d characters", key, maxClientMetadataKey)
		}
		switch v := val.(type) {
		case string:
			if utf8.RuneCountInString(v) > maxClientMetadataValue {
				return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q exceeds %d characters", key, maxClientMetadataValue)
			}
		case json.Number:
			if utf8.RuneCountInString(v.String()) > maxClientMetadataValue {
				return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q exceeds %d characters", key, maxClientMetadataValue)
			}
			if strings.ContainsAny(v.String(), ".eE") && !portalCompatibleFloat(v.String()) {
				return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q exceeds the control plane's numeric range", key)
			}
		default:
			return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q must be a string or number", key)
		}
		clean[key] = val
	}

	if len(clean) == 0 {
		return "", nil
	}

	// Re-marshal so the header is canonical (json.Marshal sorts object keys),
	// dropping any formatting the operator's raw value carried.
	canonical, err := json.Marshal(clean)
	if err != nil {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA could not be encoded: %w", err)
	}
	return string(canonical), nil
}

func portalCompatibleFloat(value string) bool {
	n, err := strconv.ParseFloat(value, 64)
	// Jason accepts finite underflow as zero, while overflow is rejected. The
	// JSON decoder has already checked syntax, so ErrRange is the only expected
	// parse error here.
	return (err == nil || errors.Is(err, strconv.ErrRange)) && !math.IsInf(n, 0)
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

// buildUserAgentWithDefault stamps every cloud request with structured client +
// host + os posture. The portal's audit pipeline extracts these from the
// User-Agent header so each audit row carries "client=claude-desktop;
// host=…; os=darwin" instead of "some MCP call from <IP>".
func buildUserAgentWithDefault(defaultClient string) string {
	client := os.Getenv("EMISAR_CLIENT")
	if client == "" {
		client = defaultClient
	}
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "unknown"
	}
	return fmt.Sprintf("%s/%s (client=%s; host=%s; os=%s)", bridgeName, Version, client, host, runtime.GOOS)
}

// newProcessNonce returns a 16-byte random hex namespace for one bridge
// process. It stays local; only fixed-length digests and request-generation
// tokens derived from it cross the transport. Failure is fatal because a
// process that cannot mint a unique namespace cannot safely correlate retries
// or concurrent requests.
func newProcessNonce(r io.Reader) (string, error) {
	var b [16]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", fmt.Errorf("process nonce: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// parseEndpoint accepts one absolute HTTP(S) origin and returns its canonical
// no-trailing-slash form. Path, credentials, query, and fragment input are
// rejected rather than silently changing where the bridge sends Bearer tokens.
// Cleartext remains limited to loopback unless explicitly enabled.
func parseEndpoint(raw string, allowInsecure bool) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", errors.New("EMISAR_URL is not a valid URL")
	}
	if !u.IsAbs() || u.Opaque != "" || u.Hostname() == "" {
		return "", errors.New("EMISAR_URL must be an absolute URL with a host")
	}
	if u.User != nil {
		return "", errors.New("EMISAR_URL must not contain user information")
	}
	if u.RawQuery != "" || u.ForceQuery {
		return "", errors.New("EMISAR_URL must not contain a query")
	}
	if u.Fragment != "" || strings.Contains(raw, "#") {
		return "", errors.New("EMISAR_URL must not contain a fragment")
	}
	if u.RawPath != "" || (u.Path != "" && u.Path != "/") {
		return "", errors.New("EMISAR_URL must be an origin without a path")
	}
	if strings.HasSuffix(u.Host, ":") {
		return "", errors.New("EMISAR_URL has an empty port")
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65_535 {
			return "", errors.New("EMISAR_URL has an invalid port")
		}
	}

	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Host)
	if (scheme == "https" && u.Port() == "443") || (scheme == "http" && u.Port() == "80") {
		host = strings.TrimSuffix(host, ":"+u.Port())
	}
	switch scheme {
	case "https":
		return scheme + "://" + host, nil
	case "http":
		if allowInsecure || isLoopbackHost(u.Hostname()) {
			return scheme + "://" + host, nil
		}
		return "", errors.New("EMISAR_URL uses cleartext http to a non-loopback host, " +
			"which sends the API key in plaintext; use https, or set " +
			"EMISAR_ALLOW_INSECURE=1 to override")
	default:
		return "", errors.New("EMISAR_URL must use http or https")
	}
}

// isLoopbackHost reports whether host is localhost or a loopback IP.
func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// allowInsecureEndpoints reports whether the operator opted out of the HTTPS
// requirement. It accepts the spellings people actually type: requiring the
// literal "1" meant EMISAR_ALLOW_INSECURE=true silently left the safety ON,
// which is the safe direction but tells the operator nothing — they set the
// variable and it did not take. The runner's own config spells this as a YAML
// boolean, so `true` is the spelling they arrive with.
func allowInsecureEndpoints() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("EMISAR_ALLOW_INSECURE"))) {
	case "1", "true", "yes", "y", "on":
		return true
	default:
		return false
	}
}
