package main

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
)

const runtimeStatusMinFreshness = 30 * time.Second

type statusReport struct {
	Status   string               `json:"status"`
	Passed   int                  `json:"passed"`
	Warnings int                  `json:"warnings"`
	Failed   int                  `json:"failed"`
	Runtime  *cloud.RuntimeStatus `json:"runtime,omitempty"`
	Checks   []doctorCheck        `json:"checks"`
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show whether the runner daemon is connected and what it is serving",
		Long: `status reads the runner daemon's owner-only local health snapshot and
correlates it with the held process lock. It reports the last successful
heartbeat send, the last catalog advertisement, process uptime, connection
attempts, and in-flight runs, then surfaces any failing local readiness checks.

The snapshot is advisory operational evidence, not control-plane proof. The
console remains authoritative for whether the control plane currently sees the
runner. Use doctor for the complete offline preflight and the service journal
for detailed connection errors.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			runtime, checks, runtimeChecks := runStatus(cmd.Context(), time.Now().UTC())
			report := newStatusReport(runtime, checks)
			if flagJSONOut {
				if err := printJSON(report); err != nil {
					return err
				}
			} else {
				reportStatus(cmd.OutOrStdout(), checks, runtimeChecks)
			}
			if report.Failed > 0 {
				return fmt.Errorf("%d status check(s) failed", report.Failed)
			}
			return nil
		},
	}
}

func newStatusReport(runtime *cloud.RuntimeStatus, checks []checkResult) statusReport {
	doctor := newDoctorReport(checks)
	return statusReport{
		Status: doctor.Status, Passed: doctor.Passed, Warnings: doctor.Warnings,
		Failed: doctor.Failed, Runtime: runtime, Checks: doctor.Checks,
	}
}

func runStatus(ctx context.Context, now time.Time) (*cloud.RuntimeStatus, []checkResult, int) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, runDoctor(ctx, false), 0
	}

	runtime, runtimeChecks, connected := checkRuntimeStatus(cfg, now)
	// A fresh authenticated websocket session is stronger current reachability
	// evidence than doctor's unauthenticated HTTP origin probe. Only spend the
	// network request when runtime evidence says the session is absent/degraded.
	doctorChecks := runDoctorChecks(ctx, false, !connected)
	return runtime, append(runtimeChecks, doctorChecks...), len(runtimeChecks)
}

func checkRuntimeStatus(cfg *config.Config, now time.Time) (*cloud.RuntimeStatus, []checkResult, bool) {
	pidBefore, heldBefore, lockErr := probeRunnerLockOwner(cfg.Paths.DataDir)
	if lockErr != nil {
		return nil, []checkResult{{"connection", checkFail, fmt.Sprintf("runner lock is unreadable: %v", lockErr)}}, false
	}

	path := cloud.RuntimeStatusPath(cfg.Paths.DataDir)
	status, statusErr := cloud.ReadRuntimeStatus(path)
	pidAfter, heldAfter, secondLockErr := probeRunnerLockOwner(cfg.Paths.DataDir)
	if secondLockErr != nil {
		return status, []checkResult{{"connection", checkFail, fmt.Sprintf("runner lock is unreadable: %v", secondLockErr)}}, false
	}
	if !heldBefore || !heldAfter {
		return status, []checkResult{{
			"connection", checkFail,
			"daemon is not running — start it with `sudo systemctl start emisar`, then run status again",
		}}, false
	}
	if pidBefore != pidAfter {
		return status, []checkResult{{"connection", checkFail, "daemon changed while status was read — run status again"}}, false
	}
	if statusErr != nil {
		return nil, []checkResult{{
			"connection", checkFail,
			fmt.Sprintf("daemon PID %d is running, but %s is unusable: %v", pidAfter, path, statusErr),
		}}, false
	}
	if status == nil {
		return nil, []checkResult{{
			"connection", checkFail,
			fmt.Sprintf("daemon PID %d is running, but it has not written %s — upgrade or restart it", pidAfter, path),
		}}, false
	}
	if status.PID != pidAfter {
		return status, []checkResult{{
			"connection", checkFail,
			fmt.Sprintf("runtime snapshot belongs to PID %d, but the live daemon is PID %d — run status again", status.PID, pidAfter),
		}}, false
	}

	connection, connected := runtimeConnectionCheck(*status, now)
	checks := []checkResult{
		connection,
		runtimeCatalogCheck(*status),
		{"process", checkOK, fmt.Sprintf("PID %d · up %s · %d connection attempt(s)",
			status.PID, compactDuration(now.Sub(status.StartedAt)), status.ConnectionAttempts)},
		{"runs", checkOK, fmt.Sprintf("%d in flight (last reported by the daemon)", status.InflightRuns)},
	}
	return status, checks, connected
}

func runtimeConnectionCheck(status cloud.RuntimeStatus, now time.Time) (checkResult, bool) {
	for _, timestamp := range []time.Time{status.StartedAt, status.UpdatedAt} {
		if timestamp.After(now) {
			return checkResult{"connection", checkFail, "runtime snapshot is dated in the future — fix the host clock and restart the runner"}, false
		}
	}

	interval := time.Duration(status.HeartbeatEverySeconds) * time.Second
	freshFor := 2*interval + 5*time.Second
	if freshFor < runtimeStatusMinFreshness {
		freshFor = runtimeStatusMinFreshness
	}
	reference := status.UpdatedAt
	if status.State == cloud.RuntimeStateConnected {
		if status.LastHeartbeatSentAt != nil {
			reference = *status.LastHeartbeatSentAt
		} else if status.ConnectedAt != nil {
			reference = *status.ConnectedAt
		}
	}
	if reference.After(now) {
		return checkResult{"connection", checkFail, "runtime heartbeat is dated in the future — fix the host clock and restart the runner"}, false
	}
	age := now.Sub(reference)
	if age > freshFor {
		return checkResult{
			"connection", checkFail,
			fmt.Sprintf("daemon status is stale (%s old; limit %s) — restart the runner", compactDuration(age), compactDuration(freshFor)),
		}, false
	}

	switch status.State {
	case cloud.RuntimeStateConnected:
		heartbeat := "first heartbeat pending"
		if status.LastHeartbeatSentAt != nil {
			heartbeat = "heartbeat sent " + compactDuration(now.Sub(*status.LastHeartbeatSentAt)) + " ago"
		}
		return checkResult{"connection", checkOK, "connected · " + heartbeat}, true
	case cloud.RuntimeStateConnecting:
		return checkResult{"connection", checkFail, "daemon is running but has not connected yet — run `emisar doctor`"}, false
	case cloud.RuntimeStateReconnecting:
		return checkResult{"connection", checkFail, "daemon lost its session and is reconnecting — run `emisar doctor`"}, false
	default:
		return checkResult{"connection", checkFail, "daemon reported that it stopped — restart the service"}, false
	}
}

func runtimeCatalogCheck(status cloud.RuntimeStatus) checkResult {
	detail := fmt.Sprintf("%d packs · %d actions advertised", status.Packs, status.Actions)
	var notes []string
	severity := checkOK
	if status.UnavailableActions > 0 {
		severity = checkWarn
		notes = append(notes, fmt.Sprintf("%d unavailable", status.UnavailableActions))
	}
	if status.AdvertisementPending {
		severity = checkWarn
		notes = append(notes, "reload waiting to advertise")
	}
	if status.DegradedPacks > 0 {
		severity = checkFail
		notes = append(notes, fmt.Sprintf("%d degraded", status.DegradedPacks))
	}
	if len(notes) == 0 {
		notes = append(notes, "all available")
	}
	return checkResult{"catalog", severity, detail + " · " + strings.Join(notes, " · ")}
}

func compactDuration(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	if duration < time.Second {
		return "<1s"
	}
	return duration.Round(time.Second).String()
}

func reportStatus(w io.Writer, checks []checkResult, runtimeChecks int) int {
	style := newStyler(w)
	fmt.Fprintln(w, "emisar status")
	fmt.Fprintln(w)

	var fails, warns int
	for _, check := range checks {
		switch check.status {
		case checkFail:
			fails++
		case checkWarn:
			warns++
		}
	}

	for i, check := range checks {
		// Runtime summary is always visible. The doctor portion stays compact:
		// healthy readiness checks collapse to one line, while every issue keeps
		// its existing actionable detail.
		if i >= runtimeChecks && check.status == checkOK {
			continue
		}
		fmt.Fprintf(w, "  %s  %-12s  %s\n", statusGlyph(style, check.status), check.name, check.detail)
	}
	localChecks := len(checks) - runtimeChecks
	localIssues := 0
	for _, check := range checks[runtimeChecks:] {
		if check.status != checkOK {
			localIssues++
		}
	}
	if localChecks > 0 && localIssues == 0 {
		fmt.Fprintf(w, "  %s  %-12s  %d local readiness checks passed\n",
			statusGlyph(style, checkOK), "checks", localChecks)
	}

	fmt.Fprintln(w)
	switch {
	case fails > 0:
		fmt.Fprintln(w, style.fail(fmt.Sprintf("%d problem(s), %d warning(s) — fix the ✗ items, then run status again.", fails, warns)))
	case warns > 0:
		fmt.Fprintln(w, style.warn(fmt.Sprintf("Runner is connected with %d warning(s).", warns)))
	default:
		fmt.Fprintln(w, style.ok("Runner is connected and healthy."))
	}
	return fails
}
