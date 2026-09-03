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
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/actionhost"
	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
	"github.com/andrewdryga/emisar/runner/internal/packs"
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

// String is the machine-readable name of a status — the JSON report's
// vocabulary, and what the human glyphs stand for.
func (s checkStatus) String() string {
	switch s {
	case checkOK:
		return "ok"
	case checkWarn:
		return "warn"
	default:
		return "fail"
	}
}

// checkResult is one line of the doctor report: a named check, its outcome,
// and a human detail explaining what was found (and, on failure, the fix).
type checkResult struct {
	name   string
	status checkStatus
	detail string
}

// doctorReport is the --json form of a preflight run: the same results the
// human report renders, with string statuses and counts so fleet tooling can
// branch on the verdict instead of parsing glyphs and banners.
type doctorReport struct {
	Status string        `json:"status"`
	Passed int           `json:"passed"`
	Warned int           `json:"warned"`
	Failed int           `json:"failed"`
	Checks []doctorCheck `json:"checks"`
}

// doctorCheck is one check in the JSON report. Detail carries the same
// operator-facing explanation (and remedy) the human line shows.
type doctorCheck struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

// newDoctorReport summarizes results. The overall status is the worst check:
// any failure fails the run, otherwise any warning warns.
func newDoctorReport(results []checkResult) doctorReport {
	report := doctorReport{Status: checkOK.String(), Checks: make([]doctorCheck, 0, len(results))}
	for _, r := range results {
		switch r.status {
		case checkFail:
			report.Failed++
		case checkWarn:
			report.Warned++
		default:
			report.Passed++
		}
		report.Checks = append(report.Checks, doctorCheck{
			Name:   r.name,
			Status: r.status.String(),
			Detail: r.detail,
		})
	}
	switch {
	case report.Failed > 0:
		report.Status = checkFail.String()
	case report.Warned > 0:
		report.Status = checkWarn.String()
	}
	return report
}

func doctorCmd() *cobra.Command {
	var probe bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run offline preflight checks for a runner that won't connect or run",
		Long: `doctor diagnoses the common reasons a runner can't connect or run
actions — before you reach for the logs. It checks the config, the
control-plane credential, the pack directories and the packs they hold, the
host binaries the installed actions need on PATH, and that the control plane
is reachable over TLS.

No control-plane session is opened and a failing check never aborts the
rest, so a single run surfaces every problem at once. Exit status is
non-zero if any check fails. --json reports the same checks as a
machine-readable object.

doctor executes no action by default: every check reads local state or opens
one HTTP request. --probe adds the online check — it runs each installed
pack's declared verify action, the same probe as 'pack verify', which
authenticates to that pack's target. Ask for it when diagnosing why a pack's
actions fail; it costs one real call per pack.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			results := runDoctor(cmd.Context(), probe)
			fails := 0
			if flagJSONOut {
				report := newDoctorReport(results)
				if err := printJSON(report); err != nil {
					return err
				}
				fails = report.Failed
			} else {
				fails = reportDoctor(os.Stdout, results)
			}
			if fails > 0 {
				return fmt.Errorf("%d preflight check(s) failed", fails)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&probe, "probe", false,
		"also run each pack's verify action against its real target (executes actions)")
	return cmd
}

// runDoctor runs every preflight check and returns one result per check.
// Config is the prerequisite — if it can't load, the checks that depend on it
// are skipped rather than run against a zero config. probe adds the one check
// that executes actions; without it doctor stays entirely offline.
func runDoctor(ctx context.Context, probe bool) []checkResult {
	return runDoctorChecks(ctx, probe, true)
}

func runDoctorChecks(ctx context.Context, probe, includeCloud bool) []checkResult {
	cfg, cfgResult := checkConfig()
	results := []checkResult{cfgResult}
	if cfg == nil {
		return results
	}

	results = append(results, checkCredential(cfg))
	results = append(results, checkSigning(cfg))
	results = append(results, checkDispatchLog(cfg))

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
	if probe {
		results = append(results, checkPackVerify(ctx))
	}

	if service := checkService(ctx); service != nil {
		results = append(results, *service)
	}

	if includeCloud {
		client := httpsecurity.RefuseDowngradeRedirects(
			httpsecurity.ClientWithTLS12(&http.Client{Timeout: cloudProbeTimeout}),
		)
		results = append(results, checkCloud(ctx, cfg, client))
	}

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
	if ignored := cfg.IgnoredKeys(); len(ignored) > 0 {
		return cfg, checkResult{"config", checkWarn, fmt.Sprintf(
			"%s; %s was written by an earlier installer and is ignored — delete the line",
			detail, strings.Join(ignored, ", "))}
	}
	return cfg, checkResult{"config", checkOK, detail}
}

// checkCredential mirrors what the connect path needs: either a persisted
// per-runner token file connect would accept, or the bootstrap enrollment key
// in the configured env var (which mints a token on first connect). The cached
// file is judged by the connect reader itself (cloud.ValidateTokenFile), so
// doctor can't pass a token the dial would reject. Only "no file yet" is the
// normal pre-enrollment case; every other rejection — exposed perms, a symlink,
// malformed or unreadable contents — keeps the runner down, and an enrollment
// key does not rescue it: connect refuses to register over a rejected cache
// rather than mint a fresh token over the evidence.
func checkCredential(cfg *config.Config) checkResult {
	tokenPath := resolveTokenPath(cfg)
	envName := cfg.Cloud.EnrollmentKeyEnv

	err := cloud.ValidateTokenFile(tokenPath)
	switch {
	case err == nil:
		return checkResult{"credential", checkOK, fmt.Sprintf("token present at %s", tokenPath)}
	case !errors.Is(err, os.ErrNotExist):
		return checkResult{"credential", checkFail, fmt.Sprintf(
			"token %s is unusable: %v — connect refuses it, so the runner stays down until it's fixed",
			tokenPath, err)}
	}

	if envName != "" && os.Getenv(envName) != "" {
		return checkResult{"credential", checkOK,
			fmt.Sprintf("$%s set — registers a token on first connect", envName)}
	}

	if envName == "" {
		return checkResult{"credential", checkFail,
			fmt.Sprintf("no token at %s and cloud.enrollment_key_env is not configured", tokenPath)}
	}
	return checkResult{"credential", checkFail,
		fmt.Sprintf("no token at %s and $%s is unset — set the enrollment key", tokenPath, envName)}
}

// checkSigning names the signed-dispatch trust anchors this host actually
// holds. The control plane does not persist signing_ca_ids, so the console
// cannot answer which CA a runner trusts — on the one feature whose point is
// not trusting the console, the host is the only authority and doctor is what
// an operator runs first. Building the verifier also proves the configured
// anchors parse and that enforcement's preconditions hold, which connect would
// otherwise be the first to discover.
func checkSigning(cfg *config.Config) checkResult {
	if !cfg.Signing.EnforceSignatures && len(cfg.Signing.TrustedCAs) == 0 {
		return checkResult{"signing", checkOK,
			"not enforced — the control plane dispatches to this runner without an attestation"}
	}
	identity, err := configIdentity(cfg)
	if err != nil {
		return checkResult{"signing", checkFail, err.Error()}
	}
	verifier, err := buildStateVerifier(cfg, identity)
	if err != nil {
		return checkResult{"signing", checkFail, err.Error()}
	}
	// NewVerifier refuses enforcement without an anchor and config.Validate
	// refuses it without trusted_cas, so a built verifier that enforces always
	// names at least one CA.
	anchors := strings.Join(verifier.CAIDs(), ", ")
	if !verifier.Enforces() {
		return checkResult{"signing", checkWarn, fmt.Sprintf(
			"trusts %s, but signing.enforce_signatures is off — the control plane may still dispatch unsigned", anchors)}
	}
	return checkResult{"signing", checkOK, fmt.Sprintf(
		"enforced, trusts %s, attestations valid for %s", anchors, verifier.MaxAge())}
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
// checkDispatchLog validates the durable dispatch log. A corrupt one makes
// connect refuse to start (deliberately — a fresh empty log could double-run
// a redelivered mutation), which is invisible from the host until you know
// where to look; this check names the file and the remedy.
func checkDispatchLog(cfg *config.Config) checkResult {
	report := cloud.InspectDispatchLog(cfg.Paths.DataDir)
	switch report.State {
	case cloud.DispatchLogAbsent:
		return checkResult{"dispatch log", checkOK, "none yet — the first connect creates it"}
	case cloud.DispatchLogLegacy:
		return checkResult{"dispatch log", checkOK,
			fmt.Sprintf("%d entries at %s (older dispatch state; connect migrates it forward)",
				report.Entries, report.Path)}
	case cloud.DispatchLogCorrupt:
		return checkResult{"dispatch log", checkFail,
			fmt.Sprintf("%s is unreadable (%v) — connect refuses to start over it. To begin a clean dispatch log, %s. Quarantining forgets replay history and may allow a redelivered action to run again",
				report.Path, report.Err, cloud.DispatchLogQuarantineGuidance(cfg.Paths.DataDir))}
	default:
		return checkResult{"dispatch log", checkOK,
			fmt.Sprintf("%d entries at %s", report.Entries, report.Path)}
	}
}

func checkPacks(dirs []string) (*packs.Registry, checkResult) {
	registry, err := packs.LoadAll(dirs, packs.LoadOptions{SkipBrokenPacks: true})
	if err != nil {
		return nil, checkResult{"packs", checkFail, err.Error()}
	}
	if degraded := registry.Degraded(); len(degraded) > 0 {
		details := make([]string, len(degraded))
		for i, d := range degraded {
			details[i] = fmt.Sprintf("%s (%s)", d.Dir, d.Reason)
		}
		return registry, checkResult{"packs", checkFail,
			fmt.Sprintf("%d loaded; %d broken and skipped: %s — repair each (emisar pack update <id>) or re-run the installer",
				len(registry.Packs()), len(degraded), strings.Join(details, "; "))}
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
		if bin := actionhost.PrimaryExecutable(action); bin != "" {
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
		action, ok := registry.Action(actionID)
		if !ok || !actionhost.PrimaryExecutableAvailable(action) {
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

// checkPackVerify runs every installed pack's declared verify action and
// aggregates the outcome into one line — the online counterpart to the
// offline "action tools" check above, and the only check that executes
// anything. It is reached only under --probe.
//
// Skips (no verify declared, an argument this host can't infer, an
// admission-blocked action) are reported but never fail the check: none of
// them means the runner is broken, and failing on them would make --probe
// permanently red on a normal fleet.
func checkPackVerify(ctx context.Context) checkResult {
	rt, err := boot()
	if err != nil {
		return checkResult{"pack verify", checkWarn, fmt.Sprintf("probe unavailable: %v", err)}
	}
	defer rt.journal.Close()

	report := newPackVerifyReport(verifyPacks(ctx, rt, rt.registry().Packs(), nil))
	if len(report.Packs) == 0 {
		return checkResult{"pack verify", checkOK, "no packs installed"}
	}

	summary := fmt.Sprintf("%d of %d packs verified", report.OK, len(report.Packs))
	if report.Skipped > 0 {
		summary += fmt.Sprintf(", %d skipped", report.Skipped)
	}
	if report.Failed == 0 {
		return checkResult{"pack verify", checkOK, summary}
	}
	var failures []string
	for _, r := range report.Packs {
		if r.Status == verifyFailed {
			failures = append(failures, fmt.Sprintf("%s (%s): %s", r.PackID, r.ActionID, r.Detail))
		}
	}
	sort.Strings(failures)
	return checkResult{"pack verify", checkFail,
		fmt.Sprintf("%s; %d failed: %s", summary, report.Failed, strings.Join(failures, "; "))}
}

// checkCloud confirms the control plane is reachable over the expected
// transport with one HTTP request (no websocket session): the connection
// proves reachability, an https probe proves TLS, and the Date header surfaces
// a skewed host clock.
func checkCloud(ctx context.Context, cfg *config.Config, client *http.Client) checkResult {
	shutdown, shutdownErr := cloud.ReadRecentTerminalShutdown(
		cloud.TerminalShutdownStatePath(cfg.Paths.DataDir), time.Now().UTC(),
	)
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
		if shutdown != nil {
			return checkResult{"cloud", checkFail, fmt.Sprintf(
				"%s; %s unreachable: %v", terminalShutdownDetail(shutdown), cfg.Cloud.URL, err)}
		}
		return checkResult{"cloud", checkFail, fmt.Sprintf("%s unreachable: %v", cfg.Cloud.URL, err)}
	}
	_ = resp.Body.Close()

	detail := "reachable " + cfg.Cloud.URL
	if strings.HasPrefix(probeURL, "https://") {
		detail += " (TLS ok)"
	}
	if shutdown != nil {
		return checkResult{"cloud", checkFail, terminalShutdownDetail(shutdown)}
	}
	if shutdownErr != nil {
		return checkResult{"cloud", checkWarn, fmt.Sprintf(
			"%s, but the terminal shutdown state could not be read: %v", detail, shutdownErr)}
	}
	if skew, ok := clockSkew(resp.Header.Get("Date")); ok && skew > clockSkewThreshold {
		return checkResult{"cloud", checkWarn, fmt.Sprintf(
			"%s, but the host clock is off by ~%s — fix NTP", detail, skew.Round(time.Second))}
	}
	return checkResult{"cloud", checkOK, detail}
}

func terminalShutdownDetail(shutdown *cloud.TerminalShutdownState) string {
	lead := "the control plane rejected this runner"
	if shutdown.Reason == cloud.ReasonProtocolVersionUnsupported {
		// Not a rejection: the peer is reachable and willing, we simply cannot
		// read what it sends.
		lead = "this runner cannot read the control plane's wire protocol"
	}
	detail := fmt.Sprintf("%s: %s", lead, shutdown.Reason)
	if shutdown.Message != "" {
		detail += " — " + shutdown.Message
	}
	switch shutdown.Reason {
	case cloud.ReasonProtocolVersionUnsupported, "runner_version_unsupported":
		return detail + "; upgrade the runner and restart it"
	case "runner_revoked":
		return detail + "; re-register the runner in the control plane and restart it"
	default:
		return detail + "; update the runner state in the control plane and restart it"
	}
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
	style := newStyler(w)
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
		fmt.Fprintf(w, "  %s  %-12s  %s\n", statusGlyph(style, r.status), r.name, r.detail)
	}

	fmt.Fprintln(w)
	switch {
	case fails > 0:
		summary := fmt.Sprintf("%d problem(s), %d warning(s) — fix the ✗ items, then run `emisar connect`.", fails, warns)
		fmt.Fprintln(w, style.fail(summary))
	case warns > 0:
		summary := fmt.Sprintf("Critical checks passed, %d warning(s) — the runner should connect.", warns)
		fmt.Fprintln(w, style.warn(summary))
	default:
		fmt.Fprintln(w, style.ok("All checks passed — the runner is ready to connect."))
	}
	return fails
}

// statusGlyph is the one-cell verdict mark, colored like the portal's
// pass/pending/deny statuses when the terminal supports it.
func statusGlyph(style styler, s checkStatus) string {
	switch s {
	case checkOK:
		return style.ok("✓")
	case checkWarn:
		return style.warn("⚠")
	default:
		return style.fail("✗")
	}
}
