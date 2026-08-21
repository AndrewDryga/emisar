package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"unicode/utf8"
)

const (
	maxCredentialImportBytes  = 16 << 10
	maxAccountNameRunes       = 80
	maxAccountSlugBytes       = 64
	defaultCLIEndpointOrigin  = "https://emisar.dev"
	accountSelectionFilename  = "current-account.json"
	accountSelectionVersion   = 1
	accountCredentialHashSize = 64
)

type accountSelection struct {
	Version        int    `json:"version"`
	EndpointOrigin string `json:"endpoint_origin"`
	AccountID      string `json:"account_id"`
}

type storedCLIAccount struct {
	store *credentialStore
	state credentialState
}

type accountListEntry struct {
	Current  bool   `json:"current"`
	ID       string `json:"id"`
	Slug     string `json:"slug"`
	Name     string `json:"name"`
	Endpoint string `json:"endpoint"`
}

func runAuthCommand(account string, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	return runAuthCommandWithDeviceAuth(account, args, stdin, stdout, stderr, newDeviceAuthenticator())
}

func runAuthCommandWithDeviceAuth(
	account string,
	args []string,
	stdin io.Reader,
	stdout, stderr io.Writer,
	authenticator deviceAuthenticator,
) int {
	if account != "" && (len(args) == 0 || args[0] != "status") {
		return cliUsageBlock(stderr, "--account only works with auth status", authUsageText)
	}
	switch {
	case len(args) == 0:
		return loginCLIAuth(account, "", stdout, stderr, authenticator)
	case len(args) == 1 && args[0] == "login":
		return loginCLIAuth(account, "", stdout, stderr, authenticator)
	case len(args) == 2 && args[0] == "login":
		if args[1] == "-h" || args[1] == "--help" {
			fmt.Fprint(stdout, authHelpText)
			return 0
		}
		return loginCLIAuth(account, args[1], stdout, stderr, authenticator)
	case len(args) == 1 && args[0] == "status":
		return showCLIAuthStatus(account, "", stdout, stderr)
	case len(args) == 2 && args[0] == "status":
		if args[1] == "-h" || args[1] == "--help" {
			fmt.Fprint(stdout, authHelpText)
			return 0
		}
		return showCLIAuthStatus(account, args[1], stdout, stderr)
	case len(args) == 1 && args[0] == "import":
		return importCLIAuth("", stdin, stdout, stderr)
	case len(args) == 2 && args[0] == "import":
		if args[1] == "-h" || args[1] == "--help" {
			fmt.Fprint(stdout, authHelpText)
			return 0
		}
		return importCLIAuth(args[1], stdin, stdout, stderr)
	case len(args) == 1 && (args[0] == "-h" || args[0] == "--help"):
		fmt.Fprint(stdout, authHelpText)
		return 0
	default:
		return cliUsageBlock(stderr, "Invalid auth command", authUsageText)
	}
}

func runAccountsCommand(args []string, stdout, stderr io.Writer) int {
	switch {
	case len(args) == 1 && args[0] == "list":
		return listCLIAccounts(false, stdout, stderr)
	case len(args) == 2 && args[0] == "list" && args[1] == "--json":
		return listCLIAccounts(true, stdout, stderr)
	case len(args) == 2 && args[0] == "list" && (args[1] == "-h" || args[1] == "--help"):
		fmt.Fprint(stdout, accountsHelpText)
		return 0
	case len(args) == 2 && args[0] == "use":
		if args[1] == "-h" || args[1] == "--help" {
			fmt.Fprint(stdout, accountsHelpText)
			return 0
		}
		if !validAccountSelector(args[1]) {
			return cliUsageError(stderr, "account must be an exact slug or account ID")
		}
		return useCLIAccount(args[1], stdout, stderr)
	case len(args) == 1 && (args[0] == "-h" || args[0] == "--help"):
		fmt.Fprint(stdout, accountsHelpText)
		return 0
	default:
		return cliUsageBlock(stderr, "Invalid accounts command", accountsUsageText)
	}
}

func validAccountID(id string) bool {
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	for index, char := range id {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func validAccountSlug(slug string) bool {
	if len(slug) < 3 || len(slug) > maxAccountSlugBytes || slug[0] < 'a' || slug[0] > 'z' {
		return false
	}
	for index, char := range []byte(slug) {
		letter := char >= 'a' && char <= 'z'
		digit := char >= '0' && char <= '9'
		if !letter && !digit && (char != '-' || index == len(slug)-1) {
			return false
		}
	}
	return true
}

func validAccountSelector(selector string) bool {
	return validAccountID(selector) || validAccountSlug(selector)
}

func validAccountName(name string) bool {
	return strings.TrimSpace(name) != "" && utf8.ValidString(name) &&
		utf8.RuneCountInString(name) <= maxAccountNameRunes &&
		displayAccountName(name) != ""
}

func displayAccountName(name string) string {
	return strings.Join(strings.Fields(terminalSafeText(name)), " ")
}

func validateAccountIdentity(id, slug, name string) error {
	switch {
	case !validAccountID(id):
		return errors.New("invalid account ID")
	case !validAccountSlug(slug):
		return errors.New("invalid account slug")
	case !validAccountName(name):
		return errors.New("invalid account name")
	default:
		return nil
	}
}

func showCLIAuthStatus(account, expectedOrigin string, stdout, stderr io.Writer) int {
	store, state, err := loadCLICredential(account)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if account == "" {
				return cliCommandError(
					stderr,
					"No account is selected",
					nil,
					"Run `emisar-mcp auth` to authenticate an account.",
					"Run `emisar-mcp accounts list` to see stored accounts.",
				)
			}
			return cliCommandError(
				stderr,
				fmt.Sprintf("Account %q is not stored", account),
				nil,
				"Run `emisar-mcp accounts list` to see stored accounts.",
				"Run `emisar-mcp auth` to add another account.",
			)
		}
		return cliCommandError(
			stderr,
			"Could not read the stored account",
			[]string{err.Error()},
			"Check the credential file and directory permissions, then try again.",
		)
	}
	if expectedOrigin != "" {
		expected, err := parseEndpoint(expectedOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
		if err != nil {
			return cliCommandError(
				stderr,
				"The server URL is invalid",
				[]string{err.Error()},
				"Use an origin such as https://emisar.dev, without a path, query, or credentials.",
			)
		}
		if expected != state.EndpointOrigin {
			return cliCommandError(
				stderr,
				"This account belongs to a different server",
				[]string{
					"Stored server: " + state.EndpointOrigin,
					"Requested server: " + expected,
				},
				"Use the stored server, or run `emisar-mcp auth login <URL>` to add the other server.",
			)
		}
	}
	fmt.Fprintf(stdout, "Account: %s (%s)\n", displayAccountName(state.AccountName), state.AccountSlug)
	fmt.Fprintf(stdout, "Account ID: %s\n", state.AccountID)
	fmt.Fprintf(stdout, "Credential stored for %s (%s)\n", state.EndpointOrigin, store.path)
	fmt.Fprintln(stdout, "Local status only. Verify access with:")
	if account == "" {
		fmt.Fprintln(stdout, "  emisar-mcp list_tools")
	} else {
		fmt.Fprintf(stdout, "  emisar-mcp --account %s list_tools\n", state.AccountID)
	}
	if authEnvironmentOverrideSet() {
		warnAuthEnvironmentOverride(stderr)
	}
	return 0
}

func importCLIAuth(rawOrigin string, stdin io.Reader, stdout, stderr io.Writer) int {
	origin, err := resolveCLIAuthOrigin("", rawOrigin)
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not choose an Emisar server",
			[]string{err.Error()},
			"Pass an origin such as `emisar-mcp auth import https://emisar.dev`.",
		)
	}
	data, err := io.ReadAll(io.LimitReader(stdin, maxCredentialImportBytes+1))
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not read the browser approval from stdin",
			[]string{err.Error()},
			"Run `emisar-mcp auth` for normal browser authentication.",
		)
	}
	if len(data) > maxCredentialImportBytes {
		return cliCommandError(
			stderr,
			"The browser approval response is too large",
			[]string{fmt.Sprintf("Expected at most %d bytes.", maxCredentialImportBytes)},
			"Run `emisar-mcp auth` for normal browser authentication.",
		)
	}
	var response deviceTokenResponse
	if err := decodeJSON(data, &response); err != nil {
		return cliCommandError(
			stderr,
			"The browser approval response is invalid",
			[]string{"Stdin must contain one JSON approval response."},
			"Run `emisar-mcp auth` for normal browser authentication.",
		)
	}
	credential, err := response.cliCredential()
	if err != nil {
		return cliCommandError(
			stderr,
			"The browser approval response is incomplete",
			[]string{"It does not contain a valid CLI credential and account identity."},
			"Run `emisar-mcp auth` for normal browser authentication.",
		)
	}
	return storeCLIAccountCredential(origin, credential, stdout, stderr)
}

func decodeStrictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return ensureJSONEOF(decoder)
}

func decodeJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return ensureJSONEOF(decoder)
}

func storeCLIAccountCredential(
	origin string,
	credential deviceCredential,
	stdout, stderr io.Writer,
) int {
	store, err := newCLIAccountCredentialStore(
		credential.AccountID,
		origin,
		keyPrefix(credential.APIKey),
	)
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not locate credential storage",
			[]string{err.Error()},
			"Check that your user configuration directory is available and writable.",
		)
	}
	state := credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  origin,
		AccountID:       credential.AccountID,
		AccountSlug:     credential.AccountSlug,
		AccountName:     credential.AccountName,
		BootstrapPrefix: keyPrefix(credential.APIKey),
		Current:         credential.APIKey,
	}
	replaced := false
	err = store.withLock(func() error {
		if err := store.validateExistingPath(); err != nil {
			return err
		}
		if data, readErr := store.ops.readFile(store.path); readErr == nil {
			previous, decodeErr := decodeCredentialState(data)
			if decodeErr == nil && previous.Current != state.Current {
				replaced = true
			}
		} else if !errors.Is(readErr, os.ErrNotExist) {
			return fmt.Errorf("read credential state: %w", readErr)
		}
		return store.persist(state)
	})
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not save the account credential",
			[]string{err.Error()},
			"Check the credential file and directory permissions, then try again.",
		)
	}
	if err := writeAccountSelection(accountSelection{
		Version:        accountSelectionVersion,
		EndpointOrigin: origin,
		AccountID:      credential.AccountID,
	}); err != nil {
		return cliCommandError(
			stderr,
			"The credential was saved, but the account could not be selected",
			[]string{err.Error()},
			fmt.Sprintf("Run `emisar-mcp accounts use %s` after fixing the credential directory permissions.", credential.AccountID),
		)
	}
	if replaced {
		fmt.Fprintf(
			stderr,
			"%s: Previous credential replaced. The old key was not revoked automatically. Revoke it at %s if it is still listed.\n\n",
			cliStyledText(stderr, "1;33", "Warning"),
			cliStyledText(stderr, "4", terminalSafeLine(origin+"/app/agents")),
		)
	}
	identity := terminalSafeLine(credential.AccountName + " (" + credential.AccountSlug + ")")
	fmt.Fprintf(
		stdout,
		"%s as %s at %s\n",
		cliStyledText(stdout, "1;32", "✓ Authenticated"),
		cliStyledText(stdout, "1", identity),
		cliStyledText(stdout, "4", terminalSafeLine(origin)),
	)
	if authEnvironmentOverrideSet() {
		fmt.Fprintln(stdout)
		warnAuthEnvironmentOverride(stderr)
	}
	return 0
}

func resolveCLIAuthOrigin(account, rawOrigin string) (string, error) {
	if rawOrigin != "" {
		return parseEndpoint(rawOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
	}
	_, state, err := loadCLICredential(account)
	switch {
	case err == nil:
		return state.EndpointOrigin, nil
	case errors.Is(err, os.ErrNotExist) && account == "":
		return defaultCLIEndpointOrigin, nil
	case errors.Is(err, os.ErrNotExist):
		return "", fmt.Errorf("account %q is not stored; run emisar-mcp accounts list", account)
	default:
		return "", fmt.Errorf("stored CLI credential: %w", err)
	}
}

func loadCLICredential(account string) (*credentialStore, credentialState, error) {
	accounts, err := loadStoredCLIAccounts()
	if err != nil {
		return nil, credentialState{}, err
	}
	var selected storedCLIAccount
	if account != "" {
		selected, err = resolveStoredCLIAccount(accounts, account)
	} else {
		selection, selectionErr := readAccountSelection()
		if selectionErr != nil {
			return nil, credentialState{}, selectionErr
		}
		selected, err = findSelectedCLIAccount(accounts, selection)
	}
	if err != nil {
		return nil, credentialState{}, err
	}
	return selected.store, selected.state, nil
}

func loadStoredCLIAccounts() ([]storedCLIAccount, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(configDir, "emisar", "credentials")
	dirInfo, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect credential directory %s: %w", dir, err)
	}
	if err := rejectUnsafeCredentialDirectory(dir); err != nil {
		return nil, fmt.Errorf("credential directory %s is unsafe: %w", dir, err)
	}
	if err := validateCredentialDirectoryAccess(dir, dirInfo); err != nil {
		return nil, fmt.Errorf("credential directory %s is unsafe: %w", dir, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("list stored accounts: %w", err)
	}

	accounts := make([]storedCLIAccount, 0)
	for _, entry := range entries {
		if !validCLIAccountFilename(entry.Name()) {
			continue
		}
		store := &credentialStore{
			path: filepath.Join(dir, entry.Name()),
			ops:  defaultCredentialFileOps(),
		}
		if err := store.validateExistingPath(); err != nil {
			return nil, fmt.Errorf("stored account %s: %w", entry.Name(), err)
		}
		data, err := store.ops.readFile(store.path)
		if err != nil {
			return nil, fmt.Errorf("read stored account %s: %w", entry.Name(), err)
		}
		state, err := decodeCredentialState(data)
		if err != nil {
			return nil, fmt.Errorf("stored account %s: %w", entry.Name(), err)
		}
		origin, err := parseEndpoint(state.EndpointOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
		if err != nil {
			return nil, fmt.Errorf("stored account %s endpoint: %w", entry.Name(), err)
		}
		expected := newCLIAccountCredentialStoreAt(configDir, state.AccountID, origin, state.BootstrapPrefix)
		if expected.path != store.path {
			return nil, fmt.Errorf("stored account %s does not match its account identity", entry.Name())
		}
		store.endpointOrigin = origin
		store.bootstrapPrefix = state.BootstrapPrefix
		store.random = expected.random
		if err := state.validate(origin, state.BootstrapPrefix); err != nil {
			return nil, fmt.Errorf("stored account %s: %w", entry.Name(), err)
		}
		accounts = append(accounts, storedCLIAccount{store: store, state: state})
	}
	sort.Slice(accounts, func(i, j int) bool {
		left := strings.ToLower(accounts[i].state.AccountName)
		right := strings.ToLower(accounts[j].state.AccountName)
		if left != right {
			return left < right
		}
		if accounts[i].state.AccountSlug != accounts[j].state.AccountSlug {
			return accounts[i].state.AccountSlug < accounts[j].state.AccountSlug
		}
		return accounts[i].state.EndpointOrigin < accounts[j].state.EndpointOrigin
	})
	return accounts, nil
}

func validCLIAccountFilename(name string) bool {
	if !strings.HasPrefix(name, cliAccountFilePrefix) || !strings.HasSuffix(name, ".json") {
		return false
	}
	hash := strings.TrimSuffix(strings.TrimPrefix(name, cliAccountFilePrefix), ".json")
	if len(hash) != accountCredentialHashSize {
		return false
	}
	for _, char := range hash {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func resolveStoredCLIAccount(accounts []storedCLIAccount, selector string) (storedCLIAccount, error) {
	if !validAccountSelector(selector) {
		return storedCLIAccount{}, errors.New("account must be an exact slug or account ID")
	}
	matches := make([]storedCLIAccount, 0, 1)
	for _, account := range accounts {
		if account.state.AccountID == selector || account.state.AccountSlug == selector {
			matches = append(matches, account)
		}
	}
	switch len(matches) {
	case 0:
		return storedCLIAccount{}, os.ErrNotExist
	case 1:
		return matches[0], nil
	default:
		return storedCLIAccount{}, fmt.Errorf("account %q is stored for multiple endpoints; run emisar-mcp accounts list --json and use its account ID", selector)
	}
}

func findSelectedCLIAccount(
	accounts []storedCLIAccount,
	selection accountSelection,
) (storedCLIAccount, error) {
	for _, account := range accounts {
		if account.state.AccountID == selection.AccountID &&
			account.state.EndpointOrigin == selection.EndpointOrigin {
			return account, nil
		}
	}
	return storedCLIAccount{}, os.ErrNotExist
}

func accountSelectionStoreAt(configDir string) *credentialStore {
	return &credentialStore{
		path: filepath.Join(configDir, "emisar", "credentials", accountSelectionFilename),
		ops:  defaultCredentialFileOps(),
	}
}

func newAccountSelectionStore() (*credentialStore, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	return accountSelectionStoreAt(configDir), nil
}

func readAccountSelection() (accountSelection, error) {
	store, err := newAccountSelectionStore()
	if err != nil {
		return accountSelection{}, err
	}
	if err := store.validateExistingPath(); err != nil {
		return accountSelection{}, err
	}
	data, err := store.ops.readFile(store.path)
	if err != nil {
		return accountSelection{}, err
	}
	if len(data) > maxCredentialStateBytes {
		return accountSelection{}, fmt.Errorf("account selection is %d bytes, limit is %d", len(data), maxCredentialStateBytes)
	}
	var selection accountSelection
	if err := decodeStrictJSON(data, &selection); err != nil {
		return accountSelection{}, fmt.Errorf("decode account selection: %w", err)
	}
	if selection.Version != accountSelectionVersion || !validAccountID(selection.AccountID) {
		return accountSelection{}, errors.New("invalid account selection")
	}
	origin, err := parseEndpoint(selection.EndpointOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
	if err != nil || origin != selection.EndpointOrigin {
		return accountSelection{}, errors.New("invalid account selection endpoint")
	}
	return selection, nil
}

func writeAccountSelection(selection accountSelection) error {
	if selection.Version != accountSelectionVersion || !validAccountID(selection.AccountID) {
		return errors.New("invalid account selection")
	}
	origin, err := parseEndpoint(selection.EndpointOrigin, os.Getenv("EMISAR_ALLOW_INSECURE") == "1")
	if err != nil || origin != selection.EndpointOrigin {
		return errors.New("invalid account selection endpoint")
	}
	store, err := newAccountSelectionStore()
	if err != nil {
		return err
	}
	return store.withLock(func() error {
		if err := store.validateExistingPath(); err != nil {
			return err
		}
		return store.persistJSON(selection)
	})
}

func listCLIAccounts(jsonOutput bool, stdout, stderr io.Writer) int {
	accounts, err := loadStoredCLIAccounts()
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not read stored accounts",
			[]string{err.Error()},
			"Check the credential file and directory permissions, then try again.",
		)
	}
	selection, selectionErr := readAccountSelection()
	if selectionErr != nil && !errors.Is(selectionErr, os.ErrNotExist) {
		return cliCommandError(
			stderr,
			"Could not read the current account selection",
			[]string{selectionErr.Error()},
			"Run `emisar-mcp accounts use <slug-or-id>` to select an account again.",
		)
	}
	environmentConfigured, environmentComplete := authEnvironmentState()
	environmentOverride := environmentComplete
	if environmentConfigured {
		warnAuthEnvironmentOverride(stderr)
	}
	entries := make([]accountListEntry, 0, len(accounts))
	for _, account := range accounts {
		entries = append(entries, accountListEntry{
			Current: !environmentOverride && selectionErr == nil &&
				account.state.AccountID == selection.AccountID &&
				account.state.EndpointOrigin == selection.EndpointOrigin,
			ID:       account.state.AccountID,
			Slug:     account.state.AccountSlug,
			Name:     displayAccountName(account.state.AccountName),
			Endpoint: account.state.EndpointOrigin,
		})
	}
	if jsonOutput {
		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(entries); err != nil {
			return cliFailure(stderr, "print accounts", err)
		}
		return 0
	}
	if len(entries) == 0 {
		fmt.Fprintln(stdout, "No accounts stored. Run: emisar-mcp auth")
		return 0
	}
	table := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "CURRENT\tACCOUNT\tSLUG\tENDPOINT")
	for _, entry := range entries {
		current := ""
		if entry.Current {
			current = "*"
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%s\n", current, entry.Name, entry.Slug, entry.Endpoint)
	}
	if err := table.Flush(); err != nil {
		return cliFailure(stderr, "print accounts", err)
	}
	return 0
}

func useCLIAccount(selector string, stdout, stderr io.Writer) int {
	environmentConfigured, environmentComplete := authEnvironmentState()
	if environmentConfigured {
		if !environmentComplete {
			return cliCommandError(
				stderr,
				"Authentication environment is incomplete",
				[]string{authEnvironmentMissingDetail() + " Tool commands will fail until both variables are set or unset."},
				"Set both EMISAR_URL and EMISAR_API_KEY, or unset both before changing the current account.",
			)
		}
		return cliCommandError(
			stderr,
			"Environment credentials are active",
			[]string{"EMISAR_URL or EMISAR_API_KEY overrides stored accounts, so changing the current account would not affect tool commands."},
			"Unset both EMISAR_URL and EMISAR_API_KEY, then run this command again.",
		)
	}
	accounts, err := loadStoredCLIAccounts()
	if err != nil {
		return cliCommandError(
			stderr,
			"Could not read stored accounts",
			[]string{err.Error()},
			"Check the credential file and directory permissions, then try again.",
		)
	}
	account, err := resolveStoredCLIAccount(accounts, selector)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cliCommandError(
				stderr,
				fmt.Sprintf("Account %q is not stored", selector),
				nil,
				"Run `emisar-mcp accounts list` to see stored accounts.",
				"Run `emisar-mcp auth` to add another account.",
			)
		}
		return cliCommandError(
			stderr,
			"The account selector is ambiguous",
			[]string{err.Error()},
			"Run `emisar-mcp accounts list --json`, then use the account ID.",
		)
	}
	if err := writeAccountSelection(accountSelection{
		Version:        accountSelectionVersion,
		EndpointOrigin: account.state.EndpointOrigin,
		AccountID:      account.state.AccountID,
	}); err != nil {
		return cliCommandError(
			stderr,
			"Could not select the account",
			[]string{err.Error()},
			"Check the credential directory permissions, then try again.",
		)
	}
	fmt.Fprintf(stdout, "Using %s (%s) at %s\n", displayAccountName(account.state.AccountName), account.state.AccountSlug, account.state.EndpointOrigin)
	return 0
}

func authEnvironmentOverrideSet() bool {
	configured, _ := authEnvironmentState()
	return configured
}

func authEnvironmentState() (configured, complete bool) {
	rawURL, urlSet := os.LookupEnv("EMISAR_URL")
	rawKey, keySet := os.LookupEnv("EMISAR_API_KEY")
	return urlSet || keySet,
		urlSet && rawURL != "" && keySet && strings.TrimSpace(rawKey) != ""
}

func authEnvironmentMissingDetail() string {
	rawURL, urlSet := os.LookupEnv("EMISAR_URL")
	rawKey, keySet := os.LookupEnv("EMISAR_API_KEY")
	problems := make([]string, 0, 2)
	switch {
	case !urlSet:
		problems = append(problems, "EMISAR_URL is not set.")
	case rawURL == "":
		problems = append(problems, "EMISAR_URL is empty.")
	}
	switch {
	case !keySet:
		problems = append(problems, "EMISAR_API_KEY is not set.")
	case strings.TrimSpace(rawKey) == "":
		problems = append(problems, "EMISAR_API_KEY is empty.")
	}
	return strings.Join(problems, " ")
}

func warnAuthEnvironmentOverride(stderr io.Writer) {
	_, complete := authEnvironmentState()
	if !complete {
		writeCLIWarning(
			stderr,
			"Authentication environment is incomplete",
			[]string{authEnvironmentMissingDetail() + " Tool commands will fail until both variables are set or unset."},
			"Set both EMISAR_URL and EMISAR_API_KEY, or unset both to use stored accounts.",
		)
		return
	}
	writeCLIWarning(
		stderr,
		"Environment credentials are active",
		[]string{"EMISAR_URL or EMISAR_API_KEY overrides stored accounts for tool commands."},
		"Unset both EMISAR_URL and EMISAR_API_KEY to use stored accounts.",
	)
}

func accountAuthHint(account string) string {
	if account == "" {
		return "run emisar-mcp auth"
	}
	return fmt.Sprintf("run emisar-mcp auth or emisar-mcp accounts list (requested %q)", account)
}

const authUsageText = `usage:
  emisar-mcp auth [login [URL]]
  emisar-mcp [--account <slug-or-id>] auth status [URL]
  emisar-mcp auth import [URL]
`

const authHelpText = `emisar-mcp auth - authenticate the direct CLI

USAGE
  emisar-mcp auth
  emisar-mcp auth login [URL]
  emisar-mcp [--account <slug-or-id>] auth status [URL]
  emisar-mcp auth import [URL]

DESCRIPTION
  With no subcommand, open the browser. Choose an account there, approve the
  CLI, and the CLI stores that account locally and makes it current. Login does
  the same thing. URL selects a custom or self-hosted endpoint.

  Status shows the current or --account credential without printing its key.
  Add URL to require an exact endpoint match. This checks the local file only.

  Import is used by install-mcp.sh and install-mcp.ps1. It reads the browser
  approval response from stdin and stores only the CLI credential. Use browser
  authentication yourself.

  Stdio MCP clients do not use these credentials. Their client configuration
  still provides EMISAR_URL and EMISAR_API_KEY.
`

const accountsUsageText = `usage:
  emisar-mcp accounts list [--json]
  emisar-mcp accounts use <slug-or-id>
`

const accountsHelpText = `emisar-mcp accounts - choose a stored account

USAGE
  emisar-mcp accounts list [--json]
  emisar-mcp accounts use <slug-or-id>

DESCRIPTION
  List shows every account authenticated in this CLI. The star marks the
  current account. --json also prints immutable account IDs for scripts and for
  disambiguating the same slug stored against more than one endpoint.

  Use changes the current account for later commands:
    emisar-mcp accounts use immersive

  To use another account once without changing the current account:
    emisar-mcp --account blitz list_runners
`
