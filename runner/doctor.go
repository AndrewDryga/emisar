package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// cloudProbeTimeout bounds the single reachability request so doctor never
// hangs on a down or firewalled control plane.
const cloudProbeTimeout = 5 * time.Second

// clockSkewThreshold is how far the host clock may drift from the control
// plane before it's worth warning about — past this, TLS validity windows
// and time-based auth start to misbehave.
const clockSkewThreshold = 5 * time.Minute

// maxPackSample caps how many pack names the packs line lists before
// summarizing the rest — `emisar pack list` carries the full set.
const maxPackSample = 12

type checkStatus int

const (
	checkOK checkStatus = iota
	checkWarn
	checkFail
)

// checkResult is one line of the doctor report: a named check, its outcome,
// and a human detail explaining what was found (and, on failure, the fix).
type checkResult struct {
	name   string
	status checkStatus
	detail string
}

func doctorCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Run offline preflight checks for a runner that won't connect or run",
		Long: `doctor diagnoses the common reasons a runner can't connect or run
actions — before you reach for the logs. It checks the config, the
control-plane credential, the pack directories and the packs they hold, the
host binaries the installed actions need on PATH, and that the control plane
is reachable over TLS.

No cloud session is opened and a failing check never aborts the rest, so a
single run surfaces every problem at once. Exit status is non-zero if any
check fails.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			results := runDoctor(cmd.Context())
			if fails := reportDoctor(os.Stdout, results); fails > 0 {
				return fmt.Errorf("%d preflight check(s) failed", fails)
			}
			return nil
		},
	}
}

// runDoctor runs every preflight check and returns one result per check.
// Config is the prerequisite — if it can't load, the checks that depend on it
// are skipped rather than run against a zero config.
func runDoctor(ctx context.Context) []checkResult {
	cfg, cfgResult := checkConfig()
	results := []checkResult{cfgResult}
	if cfg == nil {
		return results
	}

	results = append(results, checkCredential(cfg))

	packDirs := cfg.Paths.Packs
	if len(flagPacksDir) > 0 {
		packDirs = flagPacksDir
	}
	results = append(results, checkPackDirs(packDirs))

	registry, packsResult := checkPacks(packDirs)
	results = append(results, packsResult)
	if registry != nil {
		results = append(results, checkActionBinaries(registry))
	}

	client := httpsecurity.ClientWithTLS12(&http.Client{Timeout: cloudProbeTimeout})
	results = append(results, checkCloud(ctx, cfg, client))

	return results
}

// checkConfig resolves and loads the config. Load also validates, so a clean
// load means a usable config; everything else depends on it.
func checkConfig() (*config.Config, checkResult) {
	path, err := resolveConfigPath()
	if err != nil {
		return nil, checkResult{"config", checkFail, err.Error()}
	}
	cfg, err := config.Load(path)
	if err != nil {
		return nil, checkResult{"config", checkFail, err.Error()}
	}
	detail := fmt.Sprintf("%s — group %q", path, cfg.Runner.Group)
	if cfg.Runner.ID != "" {
		detail += fmt.Sprintf(", runner %q", cfg.Runner.ID)
	}
	return cfg, checkResult{"config", checkOK, detail}
}

// checkCredential mirrors what the connect path needs: either a persisted
// per-runner token file, or the bootstrap auth key in the configured env var
// (which mints a token on first connect). A token file readable by group/other
// is a warning — it's a host secret.
func checkCredential(cfg *config.Config) checkResult {
	tokenPath := cfg.Cloud.TokenPath
	envName := cfg.Cloud.AuthKeyEnv

	if tokenPath != "" {
		if info, err := os.Stat(tokenPath); err == nil && info.Size() > 0 {
			if info.Mode().Perm()&0o077 != 0 {
				return checkResult{"credential", checkWarn, fmt.Sprintf(
					"token %s is %#o — others can read it; chmod 600", tokenPath, info.Mode().Perm())}
			}
			return checkResult{"credential", checkOK, fmt.Sprintf("token present at %s", tokenPath)}
		}
	}

	if envName != "" && os.Getenv(envName) != "" {
		return checkResult{"credential", checkOK,
			fmt.Sprintf("$%s set — registers a token on first connect", envName)}
	}

	return checkResult{"credential", checkFail, credentialMissingDetail(tokenPath, envName)}
}

func credentialMissingDetail(tokenPath, envName string) string {
	switch {
	case tokenPath != "" && envName != "":
		return fmt.Sprintf("no token at %s and $%s is unset — set the bootstrap key", tokenPath, envName)
	case envName != "":
		return fmt.Sprintf("$%s is unset and no cloud.token_path is configured", envName)
	default:
		return "neither cloud.auth_key_env nor cloud.token_path is configured"
	}
}

// checkPackDirs flags configured pack dirs that don't exist — LoadAll skips a
// missing dir silently, so a typo'd path would otherwise just look like "no
// packs" with no clue why.
func checkPackDirs(dirs []string) checkResult {
	if len(dirs) == 0 {
		return checkResult{"pack dirs", checkWarn, "none configured — this runner advertises no actions"}
	}
	var missing []string
	for _, dir := range dirs {
		if _, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
			missing = append(missing, dir)
		}
	}
	if len(missing) > 0 {
		return checkResult{"pack dirs", checkWarn,
			fmt.Sprintf("configured but missing (skipped): %s", strings.Join(missing, ", "))}
	}
	return checkResult{"pack dirs", checkOK, strings.Join(dirs, ", ")}
}

// checkPacks loads every pack and lists what's installed. A load error (an
// unreadable dir, a malformed pack) fails the check with the underlying
// reason. Trust is the cloud's call at dispatch — this only confirms the local
// packs parse and what versions they are.
func checkPacks(dirs []string) (*packs.Registry, checkResult) {
	registry, err := packs.LoadAll(dirs, packs.LoadOptions{})
	if err != nil {
		return nil, checkResult{"packs", checkFail, err.Error()}
	}
	loaded := registry.Packs()
	if len(loaded) == 0 {
		return registry, checkResult{"packs", checkWarn, "none loaded — this runner advertises no actions"}
	}
	sort.Slice(loaded, func(i, j int) bool { return loaded[i].ID < loaded[j].ID })
	labels := make([]string, len(loaded))
	for i, pack := range loaded {
		labels[i] = fmt.Sprintf("%s@%s", pack.ID, pack.Version)
	}
	// A real fleet host can carry dozens of packs — cap the sample (`pack
	// list` has the full set) so the line stays scannable.
	suffix := ""
	if len(labels) > maxPackSample {
		suffix = fmt.Sprintf(", +%d more", len(labels)-maxPackSample)
		labels = labels[:maxPackSample]
	}
	return registry, checkResult{"packs", checkOK,
		fmt.Sprintf("%d loaded: %s%s", len(loaded), strings.Join(labels, ", "), suffix)}
}

// checkActionBinaries resolves the host binary each installed action invokes —
// the single most common "the runner connects but my action fails" cause. A
// missing binary is a warning: the runner still works, those actions don't.
func checkActionBinaries(registry *packs.Registry) checkResult {
	// binary -> an action that needs it, so the report names a culprit.
	needs := map[string]string{}
	for _, action := range registry.Actions() {
		if bin := actionBinary(action); bin != "" {
			if _, seen := needs[bin]; !seen {
				needs[bin] = action.ID
			}
		}
	}
	if len(needs) == 0 {
		return checkResult{"action tools", checkOK, "no external binaries required"}
	}

	var missing []string
	for bin, actionID := range needs {
		if !binaryAvailable(bin) {
			missing = append(missing, fmt.Sprintf("%s (%s)", bin, actionID))
		}
	}
	if len(missing) == 0 {
		return checkResult{"action tools", checkOK, fmt.Sprintf("all %d resolve on PATH", len(needs))}
	}
	sort.Strings(missing)
	return checkResult{"action tools", checkWarn,
		fmt.Sprintf("%d not found, those actions will fail: %s", len(missing), strings.Join(missing, ", "))}
}

// actionBinary is the host program an action runs: the command binary for an
// exec action, the interpreter for a script action.
func actionBinary(action *actionspec.Action) string {
	switch action.Kind {
	case actionspec.KindExec:
		if action.Execution.Command != nil {
			return action.Execution.Command.Binary
		}
	case actionspec.KindScript:
		if action.Execution.Script != nil {
			return action.Execution.Script.Interpreter
		}
	}
	return ""
}

// binaryAvailable reports whether a program resolves the way the executor will
// run it: a bare name through PATH, an explicit path checked on disk (the
// convention is bare PATH names everywhere except /bin/sh).
func binaryAvailable(bin string) bool {
	if strings.ContainsRune(bin, os.PathSeparator) {
		info, err := os.Stat(bin)
		return err == nil && !info.IsDir()
	}
	_, err := exec.LookPath(bin)
	return err == nil
}

// checkCloud confirms the control plane is reachable over the expected
// transport with one HTTP request (no websocket session): the connection
// proves reachability, an https probe proves TLS, and the Date header surfaces
// a skewed host clock.
func checkCloud(ctx context.Context, cfg *config.Config, client *http.Client) checkResult {
	probeURL, err := httpProbeURL(cfg.Cloud.URL)
	if err != nil {
		return checkResult{"cloud", checkFail, err.Error()}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, probeURL, nil)
	if err != nil {
		return checkResult{"cloud", checkFail, err.Error()}
	}
	resp, err := client.Do(req)
	if err != nil {
		return checkResult{"cloud", checkFail, fmt.Sprintf("%s unreachable: %v", cfg.Cloud.URL, err)}
	}
	_ = resp.Body.Close()

	detail := "reachable " + cfg.Cloud.URL
	if strings.HasPrefix(probeURL, "https://") {
		detail += " (TLS ok)"
	}
	if skew, ok := clockSkew(resp.Header.Get("Date")); ok && skew > clockSkewThreshold {
		return checkResult{"cloud", checkWarn, fmt.Sprintf(
			"%s, but the host clock is off by ~%s — fix NTP", detail, skew.Round(time.Second))}
	}
	return checkResult{"cloud", checkOK, detail}
}

// httpProbeURL maps the websocket control-plane URL to the HTTP(S) origin to
// probe: ws→http, wss→https, keeping the host, dropping the socket path.
func httpProbeURL(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("cloud.url %q is not a valid URL: %w", raw, err)
	}
	var scheme string
	switch parsed.Scheme {
	case "wss", "https":
		scheme = "https"
	case "ws", "http":
		scheme = "http"
	default:
		return "", fmt.Errorf("cloud.url %q has an unsupported scheme %q", raw, parsed.Scheme)
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("cloud.url %q has no host", raw)
	}
	return (&url.URL{Scheme: scheme, Host: parsed.Host, Path: "/"}).String(), nil
}

// clockSkew is the absolute difference between the host clock and the control
// plane's Date header, when present and parseable.
func clockSkew(dateHeader string) (time.Duration, bool) {
	if dateHeader == "" {
		return 0, false
	}
	serverTime, err := http.ParseTime(dateHeader)
	if err != nil {
		return 0, false
	}
	skew := time.Since(serverTime)
	if skew < 0 {
		skew = -skew
	}
	return skew, true
}

// reportDoctor writes the aligned report and returns the number of failed
// checks (the caller's exit signal).
func reportDoctor(w io.Writer, results []checkResult) int {
	fmt.Fprintln(w, "emisar doctor")
	fmt.Fprintln(w)

	var fails, warns int
	for _, r := range results {
		switch r.status {
		case checkFail:
			fails++
		case checkWarn:
			warns++
		}
		fmt.Fprintf(w, "  %s  %-12s  %s\n", statusGlyph(r.status), r.name, r.detail)
	}

	fmt.Fprintln(w)
	switch {
	case fails > 0:
		fmt.Fprintf(w, "%d problem(s), %d warning(s) — fix the ✗ items, then run `emisar connect`.\n", fails, warns)
	case warns > 0:
		fmt.Fprintf(w, "Critical checks passed, %d warning(s) — the runner should connect.\n", warns)
	default:
		fmt.Fprintln(w, "All checks passed — the runner is ready to connect.")
	}
	return fails
}

func statusGlyph(s checkStatus) string {
	switch s {
	case checkOK:
		return "✓"
	case checkWarn:
		return "⚠"
	default:
		return "✗"
	}
}
