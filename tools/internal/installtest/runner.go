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

// Runner exercises install.sh, including rollback and root-owned policy state.
func Runner(root string, out io.Writer) error {
	if err := ensureRunnerRoot(); err != nil {
		return err
	}
	h, err := newHarness(root, out)
	if err != nil {
		return err
	}
	defer h.close()

	checks := []struct {
		name string
		run  func(*harness) error
	}{
		{"unattended pack selection", runnerUnattendedPacks},
		{"GitHub token argv hygiene", func(h *harness) error { return githubTokenHygiene(h, "install.sh") }},
		{"enrollment state transitions", runnerEnrollmentState},
		{"binary installation rollback", runnerInstallRollback},
		{"signal-interrupted rollback", runnerSignalRollback},
		{"installed pack repair", runnerPackRepair},
		{"systemd activation", runnerSystemdActive},
		{"launchd environment wrapper", runnerLaunchdWrapper},
		{"root-owned policy state", runnerPolicyOwnership},
	}
	for _, check := range checks {
		if err := check.run(h); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
	}
	fmt.Fprintln(out, "ok: runner installer smoke test passed")
	return nil
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
		"validate_enrollment_key_input", "runner_auth_state_exists",
		"prepare_enrollment_key_update", "write_enrollment_key",
		"remove_runner_auth_state", "backup_enrollment_state",
		"restore_enrollment_state",
	}

	resetRoot := h.path("auth-reset")
	etc := filepath.Join(resetRoot, "etc")
	data := filepath.Join(resetRoot, "data")
	if err := h.mkdir(etc, data); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-AAAAAAAAAAAAAAAAAAAA\nNOMAD_TOKEN=keep-this-pack-secret\n", 0o600); err != nil {
		return err
	}
	for _, name := range []string{"token", "token.json", "runner_id", "dispatches.jsonl"} {
		if err := writeFile(filepath.Join(data, name), "", 0o600); err != nil {
			return err
		}
	}
	result := h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
confirm() { return 0; }
RESET_IDENTITY=0
RESET_RUNNER_AUTH_STATE=0
ENROLLMENT_KEY_UPDATE=0
prepare_enrollment_key_update
test "$ENROLLMENT_KEY_UPDATE" = 1
test "$RESET_RUNNER_AUTH_STATE" = 1
write_enrollment_key
remove_runner_auth_state
`, map[string]string{
		"ETC_DIR": etc, "DATA_DIR": data, "SERVICE_GROUP": "root",
		"EMISAR_ENROLLMENT_KEY": "emkey-enroll-BBBBBBBBBBBBBBBBBBBB",
		"ASSUME_YES":            "0",
	})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("interactive key update: %w", err)
	}
	if err := exactFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-BBBBBBBBBBBBBBBBBBBB\nNOMAD_TOKEN=keep-this-pack-secret\n"); err != nil {
		return err
	}
	for _, name := range []string{"token", "token.json", "runner_id"} {
		if err := requireAbsent(filepath.Join(data, name)); err != nil {
			return err
		}
	}
	if err := requireRegular(filepath.Join(data, "dispatches.jsonl")); err != nil {
		return err
	}

	unattendedRoot := h.path("auth-unattended")
	etc = filepath.Join(unattendedRoot, "etc")
	data = filepath.Join(unattendedRoot, "data")
	if err := h.mkdir(etc, data); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(etc, "runner.env"),
		"EMISAR_ENROLLMENT_KEY=emkey-enroll-CCCCCCCCCCCCCCCCCCCC\n", 0o600); err != nil {
		return err
	}
	for _, name := range []string{"token", "runner_id"} {
		if err := writeFile(filepath.Join(data, name), "", 0o600); err != nil {
			return err
		}
	}
	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
confirm() { printf 'unexpected identity-reset prompt\n' >&2; exit 1; }
RESET_IDENTITY=0
RESET_RUNNER_AUTH_STATE=0
ENROLLMENT_KEY_UPDATE=0
prepare_enrollment_key_update
test "$ENROLLMENT_KEY_UPDATE" = 1
test "$RESET_RUNNER_AUTH_STATE" = 0
write_enrollment_key
`, map[string]string{
		"ETC_DIR": etc, "DATA_DIR": data, "SERVICE_GROUP": "root",
		"EMISAR_ENROLLMENT_KEY": "emkey-enroll-DDDDDDDDDDDDDDDDDDDD",
		"ASSUME_YES":            "1",
	})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("non-destructive automation: %w", err)
	}
	for _, name := range []string{"token", "runner_id"} {
		if err := requireRegular(filepath.Join(data, name)); err != nil {
			return err
		}
	}

	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
confirm() { printf 'unexpected identity-reset prompt\n' >&2; exit 1; }
RESET_RUNNER_AUTH_STATE=0
ENROLLMENT_KEY_UPDATE=0
prepare_enrollment_key_update
test "$RESET_RUNNER_AUTH_STATE" = 1
write_enrollment_key
remove_runner_auth_state
`, map[string]string{
		"ETC_DIR": etc, "DATA_DIR": data, "SERVICE_GROUP": "root",
		"EMISAR_ENROLLMENT_KEY": "emkey-enroll-EEEEEEEEEEEEEEEEEEEE",
		"ASSUME_YES":            "1", "RESET_IDENTITY": "1",
	})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("explicit identity reset: %w", err)
	}
	for _, name := range []string{"token", "runner_id"} {
		if err := requireAbsent(filepath.Join(data, name)); err != nil {
			return err
		}
	}

	failureData := h.path("auth-failure", "data")
	if err := h.mkdir(filepath.Join(failureData, "token")); err != nil {
		return err
	}
	result = h.functions(installer, names, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
remove_runner_auth_state
`, map[string]string{"DATA_DIR": failureData})
	if err := expectFailure(result, "could not remove runner authentication state"); err != nil {
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
	if err := writeFile(filepath.Join(data, "runner_id"), "old-identity\n", 0o600); err != nil {
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
remove_runner_auth_state
printf 'new-token\n' >"$DATA_DIR/token"
printf 'new-identity\n' >"$DATA_DIR/runner_id"
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
	return exactFile(filepath.Join(data, "runner_id"), "old-identity\n")
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
	if _, err := h.successful(h.root, map[string]string{"EMISAR_PACKS": ""}, "bash", args...); err != nil {
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
	before, err := fileSHA(filepath.Join(bin, "emisar"))
	if err != nil {
		return err
	}
	badEtc := h.path("bad-etc")
	if err := h.mkdir(filepath.Join(badEtc, "config.yaml")); err != nil {
		return err
	}
	failure := h.command(h.root, map[string]string{"EMISAR_PACKS": ""}, "bash",
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
