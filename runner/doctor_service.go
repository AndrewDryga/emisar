package main

import (
	"context"
	"fmt"
	"os/exec"
	goruntime "runtime"
	"strings"
	"time"
)

// The supervisor identities the installer sets up (install.sh) — the systemd
// unit on Linux, the launchd job on macOS.
const (
	systemdUnitPath = "/etc/systemd/system/emisar.service"
	systemdUnitName = "emisar"
	launchdLabel    = "com.emisar.runner"
	launchdPlist    = "/Library/LaunchDaemons/com.emisar.runner.plist"
)

// serviceProbeTimeout bounds each supervisor query — doctor must not hang on
// a wedged systemd/launchd.
const serviceProbeTimeout = 2 * time.Second

// checkService reports the supervisor's view of the runner — "config ok but
// the service isn't running" is the top post-install confusion. Nil (no line
// at all) when no supervisor manages this host: a foreground/dev/container
// runner shouldn't see a warning about a unit it never installed.
func checkService(ctx context.Context) *checkResult {
	switch goruntime.GOOS {
	case "linux":
		return checkSystemdService(ctx)
	case "darwin":
		return checkLaunchdService(ctx)
	default:
		return nil
	}
}

func checkSystemdService(ctx context.Context) *checkResult {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return nil
	}
	if !isRegularFile(systemdUnitPath) {
		return nil
	}

	active := systemctlState(ctx, "is-active")
	enabled := systemctlState(ctx, "is-enabled")
	result := systemdServiceResult(active, enabled)
	return &result
}

// systemdServiceResult maps `is-active` × `is-enabled` output to one doctor
// line. Pure so the mapping is table-testable without a live systemd.
func systemdServiceResult(active, enabled string) checkResult {
	switch {
	case active == "active" && enabled == "enabled":
		return checkResult{"service", checkOK, "systemd: active, enabled at boot"}
	case active == "active":
		return checkResult{
			"service",
			checkWarn,
			fmt.Sprintf("systemd: active but %s — survive reboots: sudo systemctl enable %s", enabled, systemdUnitName),
		}
	default:
		return checkResult{
			"service",
			checkWarn,
			fmt.Sprintf("systemd: %s — start it: sudo systemctl start %s", active, systemdUnitName),
		}
	}
}

// systemctlState runs `systemctl <verb> emisar` and returns its one-word
// answer ("active", "inactive", "enabled", …). The command exits non-zero for
// the negative states, so the output matters, not the exit code.
func systemctlState(ctx context.Context, verb string) string {
	ctx, cancel := context.WithTimeout(ctx, serviceProbeTimeout)
	defer cancel()

	out, _ := exec.CommandContext(ctx, "systemctl", verb, systemdUnitName).Output()
	state := strings.TrimSpace(string(out))
	if state == "" {
		return "unknown"
	}
	return state
}

func checkLaunchdService(ctx context.Context) *checkResult {
	if _, err := exec.LookPath("launchctl"); err != nil {
		return nil
	}
	if !isRegularFile(launchdPlist) {
		return nil
	}

	ctx, cancel := context.WithTimeout(ctx, serviceProbeTimeout)
	defer cancel()

	// `launchctl print` exits zero only when the job is loaded in the system
	// domain — the state the installer's bootstrap leaves it in.
	err := exec.CommandContext(ctx, "launchctl", "print", "system/"+launchdLabel).Run()
	result := launchdServiceResult(err == nil)
	return &result
}

// launchdServiceResult maps the loaded probe to one doctor line. Pure for
// table tests, like systemdServiceResult.
func launchdServiceResult(loaded bool) checkResult {
	if loaded {
		return checkResult{"service", checkOK, "launchd: loaded (" + launchdLabel + ")"}
	}

	return checkResult{
		"service",
		checkWarn,
		"launchd: not loaded — start it: sudo launchctl bootstrap system " + launchdPlist,
	}
}
