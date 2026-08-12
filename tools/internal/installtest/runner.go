package installtest

import (
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

type runnerCheck struct {
	name         string
	requiresRoot bool
	run          func(*harness) error
}

// Runner exercises install.sh, including rollback and root-owned policy state.
func Runner(root string, out io.Writer) error {
	privileged, err := maybeElevateRunner()
	if err != nil {
		return err
	}
	h, err := newHarness(root, out)
	if err != nil {
		return err
	}
	defer h.close()

	passed := 0
	skipped := 0
	for _, check := range runnerChecks() {
		if check.requiresRoot && !privileged {
			fmt.Fprintf(out, "skip: runner installer %s requires root or passwordless sudo\n", check.name)
			skipped++
			continue
		}
		if err := check.run(h); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
		passed++
	}
	fmt.Fprintf(out, "ok: runner installer smoke test passed (%d passed, %d skipped)\n", passed, skipped)
	return nil
}

func runnerChecks() []runnerCheck {
	return []runnerCheck{
		{"unattended pack selection", false, runnerUnattendedPacks},
		{"GitHub token argv hygiene", false, func(h *harness) error { return githubTokenHygiene(h, "install.sh") }},
		{"enrollment state transitions", true, runnerEnrollmentState},
		{"binary installation rollback", true, runnerInstallRollback},
		{"signal-interrupted rollback", false, runnerSignalRollback},
		{"installed pack repair", false, runnerPackRepair},
		{"systemd activation", false, runnerSystemdActive},
		{"launchd environment wrapper", false, runnerLaunchdWrapper},
		{"root-owned policy state", true, runnerPolicyOwnership},
		{"latest release resolution", false, runnerLatestRelease},
		{"fresh-install service rollback", false, runnerFreshServiceRollback},
		{"config value validation", false, runnerConfigValueValidation},
	}
}

func runnerUnattendedPacks(h *harness) error {
	installer := h.repoPath("install.sh")
	names := []string{"tty_available", "require_explicit_unattended_packs"}

	result := h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
ASSUME_YES=1
PACKS_EXPLICIT=0
require_explicit_unattended_packs
`, nil)
	if err := expectFailure(result, "--yes requires an explicit pack set"); err != nil {
		return fmt.Errorf("ambiguous automation: %w", err)
	}

	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
ASSUME_YES=1
PACKS_EXPLICIT=1
require_explicit_unattended_packs
`, nil)
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("explicit automation: %w", err)
	}

	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
tty_available() { return 1; }
ASSUME_YES=0
PACKS_EXPLICIT=1
require_explicit_unattended_packs
`, nil)
	if err := expectFailure(result, "non-interactive install requires --yes"); err != nil {
		return fmt.Errorf("non-interactive install: %w", err)
	}

	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
tty_available() { return 0; }
ASSUME_YES=0
PACKS_EXPLICIT=0
require_explicit_unattended_packs
`, nil)
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("interactive recommendations: %w", err)
	}
	return nil
}

func runnerEnrollmentState(h *harness) error {
	installer := h.repoPath("install.sh")
	names := []string{
		"validate_enrollment_key_input", "prepare_enrollment_key_update",
		"write_enrollment_key", "remove_runner_token",
		"backup_enrollment_state", "restore_enrollment_state",
	}

	updateRoot := h.path("enrollment-update")
	etc := filepath.Join(updateRoot, "etc")
	data := filepath.Join(updateRoot, "data")
	if err := h.mkdir(etc, data); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-AAAAAAAAAAAAAAAAAAAA\nNOMAD_TOKEN=keep-this-pack-secret\n", 0o600); err != nil {
		return err
	}
	for name, contents := range map[string]string{
		"token":            "legacy-token\n",
		"token.json":       "current-token\n",
		"dispatches.jsonl": "durable-dispatch\n",
	} {
		if err := writeFile(filepath.Join(data, name), contents, 0o600); err != nil {
			return err
		}
	}
	result := h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
ENROLLMENT_KEY_UPDATE=0
prepare_enrollment_key_update
test "$ENROLLMENT_KEY_UPDATE" = 1
write_enrollment_key
`, map[string]string{
		"ETC_DIR": etc, "DATA_DIR": data, "SERVICE_GROUP": "root",
		"EMISAR_ENROLLMENT_KEY": "emkey-enroll-BBBBBBBBBBBBBBBBBBBB",
	})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("enrollment key update: %w", err)
	}
	if err := exactFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-BBBBBBBBBBBBBBBBBBBB\nNOMAD_TOKEN=keep-this-pack-secret\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(data, "token"), "legacy-token\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(data, "token.json"), "current-token\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(data, "dispatches.jsonl"), "durable-dispatch\n"); err != nil {
		return err
	}

	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
remove_runner_token
`, map[string]string{"DATA_DIR": data})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("token removal: %w", err)
	}
	for _, name := range []string{"token", "token.json"} {
		if err := requireAbsent(filepath.Join(data, name)); err != nil {
			return err
		}
	}
	if err := exactFile(filepath.Join(data, "dispatches.jsonl"), "durable-dispatch\n"); err != nil {
		return err
	}

	failureData := h.path("token-removal-failure", "data")
	if err := h.mkdir(filepath.Join(failureData, "token")); err != nil {
		return err
	}
	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
remove_runner_token
`, map[string]string{"DATA_DIR": failureData})
	if err := expectFailure(result, "could not remove runner token"); err != nil {
		return fmt.Errorf("removal failure: %w", err)
	}

	rollbackRoot := h.path("auth-rollback")
	etc = filepath.Join(rollbackRoot, "etc")
	data = filepath.Join(rollbackRoot, "data")
	backup := filepath.Join(rollbackRoot, "backup")
	if err := h.mkdir(etc, data, backup); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-FFFFFFFFFFFFFFFFFFFF\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(data, "token"), "old-token\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(data, "token.json"), "old-token-json\n", 0o600); err != nil {
		return err
	}
	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
ENROLLMENT_KEY_UPDATE=1
ENROLLMENT_STATE_BACKED_UP=0
tmp="$BACKUP_DIR" backup_enrollment_state
write_enrollment_key
printf 'new-token\n' >"$DATA_DIR/token"
printf 'new-token-json\n' >"$DATA_DIR/token.json"
ENROLLMENT_STATE_BACKED_UP=1 tmp="$BACKUP_DIR" restore_enrollment_state
`, map[string]string{
		"ETC_DIR": etc, "DATA_DIR": data, "SERVICE_GROUP": "root",
		"EMISAR_ENROLLMENT_KEY": "emkey-enroll-GGGGGGGGGGGGGGGGGGGG",
		"BACKUP_DIR":            backup,
	})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("rollback: %w", err)
	}
	if err := exactFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-FFFFFFFFFFFFFFFFFFFF\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(data, "token"), "old-token\n"); err != nil {
		return err
	}
	return exactFile(filepath.Join(data, "token.json"), "old-token-json\n")
}

func runnerInstallRollback(h *harness) error {
	bin := h.path("bin")
	etc := h.path("etc")
	data := h.path("data")
	logDir := h.path("log")
	if err := h.mkdir(bin, etc, data, logDir); err != nil {
		return err
	}
	args := []string{
		h.repoPath("install.sh"), "--yes", "--no-service",
		"--bin-dir", bin, "--etc-dir", etc, "--data-dir", data, "--log-dir", logDir,
	}
	installed, err := h.successful(h.root, map[string]string{"EMISAR_PACKS": ""}, "bash", args...)
	if err != nil {
		return err
	}
	if err := h.requireAttestationOutcome(map[string]string{"EMISAR_PACKS": ""}, installed); err != nil {
		return err
	}
	versionOutput, err := h.successful(h.root, nil, filepath.Join(bin, "emisar"), "--version")
	if err != nil {
		return err
	}
	version, err := matchedVersion(runnerVersion, versionOutput)
	if err != nil {
		return err
	}
	receipt := filepath.Join(etc, "install-receipt")
	locator := filepath.Join(bin, ".emisar-install-receipt")
	if err := exactFile(locator, receipt+"\n"); err != nil {
		return fmt.Errorf("installer receipt locator: %w", err)
	}
	for _, want := range []string{
		"schema=1", "manager=install.sh", "repository=andrewdryga/emisar",
		"binary=" + filepath.Join(bin, "emisar"), "etc_dir=" + etc,
		"data_dir=" + data, "log_dir=" + logDir, "init=none",
	} {
		if err := containsFile(receipt, want+"\n"); err != nil {
			return fmt.Errorf("installer receipt: %w", err)
		}
	}
	receiptInfo, err := os.Stat(receipt)
	if err != nil {
		return err
	}
	stat, ok := receiptInfo.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || receiptInfo.Mode().Perm() != 0o600 {
		return fmt.Errorf("receipt owner/mode = %#v %s, want uid 0 mode 0600", receiptInfo.Sys(), receiptInfo.Mode())
	}

	marker := filepath.Join(etc, "packs", ".update-preserved")
	if err := h.mkdir(filepath.Dir(marker)); err != nil {
		return err
	}
	if err := writeFile(marker, "packs stay put\n", 0o600); err != nil {
		return err
	}
	bundle := h.path("preverified-bundle")
	if err := h.mkdir(bundle); err != nil {
		return err
	}
	for source, destination := range map[string]string{
		filepath.Join(bin, "emisar"): filepath.Join(bundle, "emisar"),
		h.repoPath("install.sh"):     filepath.Join(bundle, "install.sh"),
	} {
		contents, readErr := os.ReadFile(source)
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(destination, contents, 0o755); writeErr != nil {
			return writeErr
		}
	}
	handoff, err := h.successful(h.root, map[string]string{"EMISAR_PACKS": ""}, "bash",
		filepath.Join(bundle, "install.sh"), "--yes", "--no-service",
		"--version", "runner-v"+version, "--packs", "",
		"--bin-dir", bin, "--etc-dir", etc, "--data-dir", data, "--log-dir", logDir,
		"--preverified-bundle", bundle)
	if err != nil {
		return err
	}
	if !strings.Contains(string(handoff), "preserving installed packs") {
		return fmt.Errorf("preverified handoff did not name pack preservation:\n%s", handoff)
	}
	if err := exactFile(marker, "packs stay put\n"); err != nil {
		return fmt.Errorf("preverified handoff changed packs: %w", err)
	}

	before, err := fileSHA(filepath.Join(bin, "emisar"))
	if err != nil {
		return err
	}
	badEtc := h.path("bad-etc")
	if err := h.mkdir(badEtc); err != nil {
		return err
	}
	failureEnv := map[string]string{
		"EMISAR_PACKS":      "",
		"RUNNER_LABEL_ROLE": "invalid label",
	}
	failure := h.command(h.root, failureEnv, "bash",
		h.repoPath("install.sh"), "--yes", "--no-service", "--version", "runner-v"+version,
		"--bin-dir", bin, "--etc-dir", badEtc, "--data-dir", data, "--log-dir", logDir)
	if err := expectFailure(failure, "restored previous binary after failed upgrade"); err != nil {
		return err
	}
	after, err := fileSHA(filepath.Join(bin, "emisar"))
	if err != nil {
		return err
	}
	if before != after {
		return fmt.Errorf("failed upgrade changed the installed binary")
	}
	return nil
}

// A bare signal fires the EXIT trap with $?=0, which finish_install's rc-guard
// reads as success — do_install converts HUP/INT/TERM into 128+signum exits so
// a Ctrl-C mid-swap still rolls back. The wiring is inline in do_install, so
// pin the exact trap lines to the script, then reproduce them verbatim around
// the real finish_install and self-kill.
func runnerSignalRollback(h *harness) error {
	installer := h.repoPath("install.sh")
	trapLines := []string{
		"trap 'finish_install $?' EXIT",
		"trap 'exit 129' HUP",
		"trap 'exit 130' INT",
		"trap 'exit 143' TERM",
	}
	for _, line := range trapLines {
		if err := containsFile(installer, line); err != nil {
			return err
		}
	}
	for _, signal := range []struct {
		name string
		code int
	}{{"HUP", 129}, {"INT", 130}, {"TERM", 143}} {
		result := h.functions(installer, []string{"finish_install"}, `
rollback_binary() { echo "rollback ran"; }
restore_enrollment_state() { :; }
restore_previous_service() { :; }
rollback_install_receipt() { :; }
rollback_service() { :; }
warn() { :; }
INSTALL_TRANSACTION=1
tmp=""
`+strings.Join(trapLines, "\n")+`
kill -`+signal.name+` $$
sleep 5
echo "signal did not interrupt"
`, nil)
		if code := exitCode(result.err); code != signal.code {
			return fmt.Errorf("SIG%s exited %d, expected %d\n%s",
				signal.name, code, signal.code, result.output)
		}
		if !strings.Contains(string(result.output), "rollback ran") {
			return fmt.Errorf("SIG%s skipped the rollback:\n%s", signal.name, result.output)
		}
	}
	return nil
}

func runnerPackRepair(h *harness) error {
	bin := h.path("repair-bin")
	etc := h.path("repair-etc")
	if err := h.mkdir(bin, filepath.Join(etc, "packs", "cloud-init")); err != nil {
		return err
	}
	marker := h.path("repaired")
	if err := fakeExecutable(filepath.Join(bin, "emisar"), `
case "$*" in
  "pack list --packs-dir "*) test -f "$EMISAR_REPAIR_MARKER" ;;
  "pack update --packs-dir "*) : >"$EMISAR_REPAIR_MARKER" ;;
  *) exit 2 ;;
esac
`); err != nil {
		return err
	}
	result := h.functions(h.repoPath("install.sh"),
		[]string{"repair_installed_packs", "verify_installed_packs"}, `
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
repair_installed_packs
verify_installed_packs
`, map[string]string{
			"BIN_DIR": bin, "ETC_DIR": etc, "EMISAR_REPAIR_MARKER": marker,
		})
	if _, err := requireOutput(result); err != nil {
		return err
	}
	return requireRegular(marker)
}

func runnerSystemdActive(h *harness) error {
	fakeBin := h.path("fake-systemd-bin")
	if err := h.mkdir(fakeBin); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(fakeBin, "systemctl"), `
if [ "$1" = "is-active" ]; then
  printf '%s\n' "$FAKE_SYSTEMD_STATE"
  [ "$FAKE_SYSTEMD_STATE" = active ]
fi
`); err != nil {
		return err
	}
	path := fakeBin + string(os.PathListSeparator) + os.Getenv("PATH")
	body := `
die() { printf '%s\n' "$*" >&2; exit 1; }
SERVICE_STARTED=0
require_systemd_service_active
printf '%s\n' "$SERVICE_STARTED"
`
	result := h.functions(h.repoPath("install.sh"), []string{"require_systemd_service_active"},
		body, map[string]string{"PATH": path, "FAKE_SYSTEMD_STATE": "activating"})
	if err := expectFailure(result, "did not stay active"); err != nil {
		return err
	}
	result = h.functions(h.repoPath("install.sh"), []string{"require_systemd_service_active"},
		body, map[string]string{"PATH": path, "FAKE_SYSTEMD_STATE": "active"})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != "1" {
		return fmt.Errorf("unexpected active output %q", output)
	}
	return nil
}

func runnerLaunchdWrapper(h *harness) error {
	wrapper, err := heredocBody(h.repoPath("install.sh"), "launchd_runner_script", "LAUNCHD_RUNNER")
	if err != nil {
		return err
	}
	wrapperPath := h.path("run-launchd.sh")
	if err := writeFile(wrapperPath, wrapper, 0o755); err != nil {
		return err
	}
	output := h.path("launchd.out")
	fakeRunner := h.path("fake-emisar")
	if err := fakeExecutable(fakeRunner, `printf '%s\n' "$EMISAR_SMOKE_SECRET" "$@" >"$EMISAR_SMOKE_OUTPUT"`); err != nil {
		return err
	}
	envFile := h.path("runner.env")
	if err := writeFile(envFile, "EMISAR_SMOKE_SECRET=loaded\nEMISAR_SMOKE_OUTPUT="+output+"\n", 0o600); err != nil {
		return err
	}
	config := h.path("config path.yaml")
	if err := writeFile(config, "", 0o600); err != nil {
		return err
	}
	if _, err := h.successful(h.root, nil, wrapperPath, fakeRunner, config, envFile); err != nil {
		return err
	}
	return exactFile(output, "loaded\n--config\n"+config+"\nconnect\n")
}

func nonRootAccount() (string, string, int, int, error) {
	if uid, uidErr := strconv.Atoi(os.Getenv("SUDO_UID")); uidErr == nil && uid > 0 {
		gid, gidErr := strconv.Atoi(os.Getenv("SUDO_GID"))
		if gidErr != nil {
			return "", "", 0, 0, fmt.Errorf("parsing SUDO_GID: %w", gidErr)
		}
		account, err := user.LookupId(strconv.Itoa(uid))
		if err != nil {
			return "", "", 0, 0, fmt.Errorf("looking up invoking user: %w", err)
		}
		group, err := user.LookupGroupId(strconv.Itoa(gid))
		if err != nil {
			return "", "", 0, 0, fmt.Errorf("looking up invoking group: %w", err)
		}
		return account.Username, group.Name, uid, gid, nil
	}
	account, err := user.Lookup("nobody")
	if err != nil {
		return "", "", 0, 0, fmt.Errorf("looking up nobody: %w", err)
	}
	uid, err := strconv.Atoi(account.Uid)
	if err != nil || uid < 1 {
		return "", "", 0, 0, fmt.Errorf("nobody has unusable uid %q", account.Uid)
	}
	gid, err := strconv.Atoi(account.Gid)
	if err != nil || gid < 1 {
		return "", "", 0, 0, fmt.Errorf("nobody has unusable gid %q", account.Gid)
	}
	group, err := user.LookupGroupId(account.Gid)
	if err != nil {
		return "", "", 0, 0, fmt.Errorf("looking up nobody group: %w", err)
	}
	return account.Username, group.Name, uid, gid, nil
}

func runnerPolicyOwnership(h *harness) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	serviceUser, serviceGroup, uid, gid, err := nonRootAccount()
	if err != nil {
		return err
	}
	etc := h.path("service-etc")
	data := h.path("service-data")
	logDir := h.path("service-log")
	pack := filepath.Join(etc, "packs", "test")
	if err := h.mkdir(etc, data, logDir, filepath.Join(pack, "actions")); err != nil {
		return err
	}
	config := filepath.Join(etc, "config.yaml")
	manifest := filepath.Join(pack, "pack.yaml")
	if err := writeFile(config, "signing:\n  enforce: true\n", 0o640); err != nil {
		return err
	}
	if err := writeFile(manifest, "", 0o644); err != nil {
		return err
	}
	if err := filepath.Walk(filepath.Join(etc, "packs"), func(path string, _ os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		return os.Chown(path, uid, gid)
	}); err != nil {
		return fmt.Errorf("preparing non-root pack tree: %w", err)
	}

	result := h.functions(h.repoPath("install.sh"), []string{"ensure_dirs", "secure_pack_tree"}, `
log() { :; }
ensure_dirs
secure_pack_tree
`, map[string]string{
		"SERVICE_USER": serviceUser, "SERVICE_GROUP": serviceGroup,
		"OS": "linux", "INIT": "systemd", "ETC_DIR": etc,
		"DATA_DIR": data, "LOG_DIR": logDir,
	})
	if _, err := requireOutput(result); err != nil {
		return err
	}
	for _, path := range []string{config, manifest} {
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("cannot inspect owner for %s", path)
		}
		if stat.Uid != 0 {
			return fmt.Errorf("%s owner uid = %d, expected root", path, stat.Uid)
		}
	}
	return nil
}

// runnerLatestRelease proves what an unpinned `curl | sudo bash` installs.
//
// The GitHub releases API orders by CREATION, so two things could decide
// "latest" for every fresh install: a prerelease or draft sitting at the top,
// and a backport to an older line published after a newer minor. The fixture
// carries both, plus 0.9.9 vs 0.10.0 so a lexical sort cannot pass by accident.
func runnerLatestRelease(h *harness) error {
	const releases = `[` +
		`{"tag_name":"runner-v0.11.0","draft":true,"prerelease":false},` +
		`{"tag_name":"runner-v0.10.1","draft":false,"prerelease":true},` +
		`{"tag_name":"runner-v0.2.9","draft":false,"prerelease":false},` +
		`{"tag_name":"runner-v0.10.0","draft":false,"prerelease":false},` +
		`{"tag_name":"runner-v0.9.9","draft":false,"prerelease":false},` +
		`{"tag_name":"mcp-v9.9.9","draft":false,"prerelease":false}]`

	result := h.functions(h.repoPath("install.sh"), []string{"resolve_latest_version"}, `
github_api() { printf '%s' "$RELEASES"; }
die() { printf '%s\n' "$1" >&2; exit 1; }
REPO=example/emisar
resolve_latest_version
`, map[string]string{"RELEASES": releases})

	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if got := strings.TrimSpace(string(output)); got != "runner-v0.10.0" {
		return fmt.Errorf("resolved latest = %q, want runner-v0.10.0", got)
	}
	return nil
}

// runnerFreshServiceRollback proves a FAILED FRESH install leaves no enabled
// unit behind.
//
// rollback_binary removes the binary, and restore_previous_service only
// restarts a service that was ALREADY running — so on a fresh install nothing
// undid the enablement, and the host booted forever retrying a missing
// ExecStart. The header promises nothing partially applied is left "running but
// broken".
//
// The other half matters just as much: on an UPGRADE the unit predates this run
// and belongs to the installation being restored, so the same function must do
// nothing.
func runnerFreshServiceRollback(h *harness) error {
	trace := h.path("service-trace")
	script := `
systemctl() { printf 'systemctl %s\n' "$*" >>"$TRACE"; }
launchctl() { printf 'launchctl %s\n' "$*" >>"$TRACE"; }
rm() { printf 'rm %s\n' "$*" >>"$TRACE"; }
log() { :; }
INIT=systemd

printf 'fresh:\n' >>"$TRACE"
SERVICE_UNIT_CREATED=1
rollback_service

printf 'upgrade:\n' >>"$TRACE"
SERVICE_UNIT_CREATED=0
rollback_service
`
	result := h.functions(h.repoPath("install.sh"), []string{"rollback_service"}, script,
		map[string]string{"TRACE": trace})
	if _, err := requireOutput(result); err != nil {
		return err
	}
	recorded, err := os.ReadFile(trace)
	if err != nil {
		return err
	}
	fresh, upgrade, found := strings.Cut(string(recorded), "upgrade:\n")
	if !found {
		return fmt.Errorf("rollback_service trace is malformed:\n%s", recorded)
	}
	for _, want := range []string{"systemctl disable --now emisar.service", "rm -f /etc/systemd/system/emisar.service"} {
		if !strings.Contains(fresh, want) {
			return fmt.Errorf("a failed fresh install did not run %q:\n%s", want, fresh)
		}
	}
	if strings.TrimSpace(upgrade) != "" {
		return fmt.Errorf("a failed UPGRADE removed the pre-existing unit:\n%s", upgrade)
	}
	return nil
}

// runnerConfigValueValidation proves nothing that could break out of config.yaml
// gets baked into it.
//
// Labels, the runner group and the cloud URL all land inside YAML scalars. A
// quote does not corrupt the file, it ADDS to it — and a newline injects whole
// config KEYS: cloud.url, paths.packs, admission. Cloud-init rendering an
// instance tag into RUNNER_LABEL_* is the realistic source, so this is not a
// hypothetical hostile operator.
func runnerConfigValueValidation(h *harness) error {
	accepted := []string{"web", "us-east-1", "prod_2", "wss://emisar.dev", "host.example.net"}
	rejected := []string{
		`web"`,
		"web\n  cloud:",
		"web\n    url: wss://evil.example",
		"web $(id)",
		"web`id`",
		"",
	}

	for _, value := range accepted {
		result := h.functions(h.repoPath("install.sh"), []string{"safe_config_value"},
			"safe_config_value \"$CANDIDATE\"\n", map[string]string{"CANDIDATE": value})
		if result.err != nil {
			return fmt.Errorf("legitimate value %q was rejected:\n%s", value, result.output)
		}
	}
	for _, value := range rejected {
		result := h.functions(h.repoPath("install.sh"), []string{"safe_config_value"},
			"safe_config_value \"$CANDIDATE\"\n", map[string]string{"CANDIDATE": value})
		if result.err == nil {
			return fmt.Errorf("value %q would have been baked into config.yaml", value)
		}
	}
	return nil
}
