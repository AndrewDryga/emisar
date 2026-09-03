//go:build !windows

package installtest

import (
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
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
		{"help contract", false, runnerHelpContract},
		{"unattended pack selection", false, runnerUnattendedPacks},
		{"owned directory validation", false, runnerOwnedDirectoryValidation},
		{"GitHub token argv hygiene", false, func(h *harness) error { return githubTokenHygiene(h, "install.sh") }},
		{"attestation release epochs", false, runnerAttestationReleaseEpochs},
		{"download checksum mismatch", false, runnerDownloadChecksum},
		{"enrollment state transitions", true, runnerEnrollmentState},
		{"binary installation rollback", true, runnerInstallRollback},
		{"dispatch-state recovery boundary", false, runnerDispatchStateRollback},
		{"signal-interrupted rollback", false, runnerSignalRollback},
		{"installed pack repair", false, runnerPackRepair},
		{"systemd activation", false, runnerSystemdActive},
		{"launchd environment wrapper", false, runnerLaunchdWrapper},
		{"root-owned policy state", true, runnerPolicyOwnership},
		{"latest release resolution", false, runnerLatestRelease},
		{"fresh-install service rollback", false, runnerFreshServiceRollback},
		{"config value validation", false, runnerConfigValueValidation},
		{"runner id override in config skeleton", false, runnerIDOverride},
	}
}

func runnerHelpContract(h *harness) error {
	output, err := requireOutput(h.command(h.root, nil, "bash", h.repoPath("install.sh"), "--help"))
	if err != nil {
		return err
	}
	if !strings.Contains(string(output), "EMISAR_ATTESTATION_WORKFLOW") {
		return fmt.Errorf("installer help omits EMISAR_ATTESTATION_WORKFLOW:\n%s", output)
	}
	contract, err := requireOutput(h.command(h.root, nil, "bash", h.repoPath("install.sh"), "--managed-update-contract"))
	if err != nil {
		return fmt.Errorf("managed-update contract: %w", err)
	}
	if strings.TrimSpace(string(contract)) != "emisar-managed-update-v1" {
		return fmt.Errorf("managed-update contract = %q", contract)
	}
	return nil
}

func runnerAttestationReleaseEpochs(h *harness) error {
	trace := h.path("runner-attestation-argv")
	result := h.functions(h.repoPath("install.sh"), []string{"select_attestation_policy", "verify_attestation"}, `
log() { :; }
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
gh() {
  if [ "${1:-}" = "auth" ]; then
    return 0
  fi
  printf '%s' "$1" >>"$TRACE"
  shift
  printf '|%s' "$@" >>"$TRACE"
  printf '\n' >>"$TRACE"
}

OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
for VERSION in runner-v0.22.1 runner-v0.22.2 runner-v0.21.99; do
  ATTESTATION_WORKFLOW=
  select_attestation_policy
  printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"
done
REPO=example/emisar
VERSION=runner-v0.22.1
ATTESTATION_WORKFLOW=
select_attestation_policy
printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"

VERSION=runner-v0.22.1
ATTESTATION_WORKFLOW=example/emisar/.github/workflows/release.yml
select_attestation_policy
printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"

REPO=$OFFICIAL_REPO
for VERSION in runner-v0.22.1 runner-v0.22.2; do
  ATTESTATION_WORKFLOW=
  select_attestation_policy
  verify_attestation /verified/runner.tar.gz runner.tar.gz
done
REPO=example/emisar
VERSION=runner-v0.22.1
ATTESTATION_WORKFLOW=example/emisar/.github/workflows/release.yml
select_attestation_policy
verify_attestation /verified/runner.tar.gz runner.tar.gz
`, map[string]string{"TRACE": trace})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	const expected = "AndrewDryga/emisar/.github/workflows/runner-release.yml|642128eb48205405fd44ce845118e6a68737eea2|refs/tags/runner-v0.22.1|1\n" +
		"AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml||refs/tags/runner-v0.22.2|1\n" +
		"AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml||refs/tags/runner-v0.21.99|1\n" +
		"|||0\n" +
		"example/emisar/.github/workflows/release.yml|||0\n"
	if string(output) != expected {
		return fmt.Errorf("attestation policies = %q, want %q", output, expected)
	}
	const expectedTrace = "attestation|verify|/verified/runner.tar.gz|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/runner-release.yml|--source-ref|refs/tags/runner-v0.22.1|--signer-digest|642128eb48205405fd44ce845118e6a68737eea2|--deny-self-hosted-runners\n" +
		"attestation|verify|/verified/runner.tar.gz|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml|--source-ref|refs/tags/runner-v0.22.2|--deny-self-hosted-runners\n" +
		"attestation|verify|/verified/runner.tar.gz|--repo|example/emisar|--signer-workflow|example/emisar/.github/workflows/release.yml\n"
	return exactFile(trace, expectedTrace)
}

func runnerOwnedDirectoryValidation(h *harness) error {
	installer := h.repoPath("install.sh")
	inputs := []struct {
		env  string
		flag string
	}{
		{env: "BIN_DIR", flag: "--bin-dir"},
		{env: "ETC_DIR", flag: "--etc-dir"},
		{env: "DATA_DIR", flag: "--data-dir"},
		{env: "LOG_DIR", flag: "--log-dir"},
	}
	safe := map[string]string{
		"BIN_DIR":  h.path("owned-dir-validation", "safe", "bin"),
		"ETC_DIR":  h.path("owned-dir-validation", "safe", "etc"),
		"DATA_DIR": h.path("owned-dir-validation", "safe", "data"),
		"LOG_DIR":  h.path("owned-dir-validation", "safe", "log"),
	}

	mutationBin := h.path("owned-dir-validation", "mutation-bin")
	mutationTrace := h.path("owned-dir-validation", "mutations")
	if err := h.mkdir(mutationBin); err != nil {
		return err
	}
	for _, command := range []string{"mkdir", "chown", "chmod", "rm"} {
		if err := fakeExecutable(filepath.Join(mutationBin, command),
			`printf '%s\n' "$0 $*" >>"$MUTATION_TRACE"`); err != nil {
			return err
		}
	}
	if err := fakeExecutable(filepath.Join(mutationBin, "id"), `
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exit 1
`); err != nil {
		return err
	}

	for index, input := range inputs {
		for _, source := range []string{"flag", "environment"} {
			if err := os.WriteFile(mutationTrace, nil, 0o600); err != nil {
				return err
			}
			env := map[string]string{
				"BIN_DIR": safe["BIN_DIR"], "ETC_DIR": safe["ETC_DIR"],
				"DATA_DIR": safe["DATA_DIR"], "LOG_DIR": safe["LOG_DIR"],
				"MUTATION_TRACE": mutationTrace,
				"PATH":           mutationBin + string(os.PathListSeparator) + os.Getenv("PATH"),
			}
			component := "/./victim"
			if index%2 == 1 {
				component = "/../victim"
			}
			invalid := h.path("owned-dir-validation", fmt.Sprintf("case-%d", index)) + component
			args := []string{installer, "--yes", "--no-service", "--uninstall", "--purge"}
			if source == "environment" {
				env[input.env] = invalid
			} else {
				for _, candidate := range inputs {
					value := safe[candidate.env]
					if candidate.env == input.env {
						value = invalid
					}
					args = append(args, candidate.flag, value)
				}
			}

			result := h.command(h.root, env, "bash", args...)
			if err := expectFailure(result, "must not contain . or .. path components"); err != nil {
				return fmt.Errorf("%s from %s: %w", input.env, source, err)
			}
			if code := exitCode(result.err); code != 2 {
				return fmt.Errorf("%s from %s exited %d, want validation exit 2", input.env, source, code)
			}
			if err := exactFile(mutationTrace, ""); err != nil {
				return fmt.Errorf("%s from %s reached a mutating command: %w", input.env, source, err)
			}
		}
	}

	for _, root := range []string{"/etc", "/etc/", "/var/lib", "/var/lib/", "/var/log", "/var/log/"} {
		result := h.functions(installer, []string{"reject_dir", "require_owned_dir"},
			`require_owned_dir TEST_DIR "$CANDIDATE"`+"\n", map[string]string{"CANDIDATE": root})
		if err := expectFailure(result, "must not be a system directory"); err != nil {
			return fmt.Errorf("system root %q: %w", root, err)
		}
	}
	for _, candidate := range []string{
		"/./tmp/emisar", "/tmp/./emisar", "/tmp/emisar/.", "/tmp/emisar/./",
		"/../tmp/emisar", "/tmp/../emisar", "/tmp/emisar/..", "/tmp/emisar/../",
	} {
		result := h.functions(installer, []string{"reject_dir", "require_owned_dir"},
			`require_owned_dir TEST_DIR "$CANDIDATE"`+"\n", map[string]string{"CANDIDATE": candidate})
		if err := expectFailure(result, "must not contain . or .. path components"); err != nil {
			return fmt.Errorf("dot component %q: %w", candidate, err)
		}
	}
	for _, candidate := range []string{"//etc", "/etc//", "/var//lib", "/var/lib//"} {
		result := h.functions(installer, []string{"reject_dir", "require_owned_dir"},
			`require_owned_dir TEST_DIR "$CANDIDATE"`+"\n", map[string]string{"CANDIDATE": candidate})
		if err := expectFailure(result, "must not contain repeated path separators"); err != nil {
			return fmt.Errorf("repeated separator %q: %w", candidate, err)
		}
	}
	for _, input := range inputs {
		result := h.functions(installer, []string{"reject_dir", "require_owned_dir"},
			`require_owned_dir TEST_DIR "$CANDIDATE"`+"\n", map[string]string{"CANDIDATE": safe[input.env]})
		if _, err := requireOutput(result); err != nil {
			return fmt.Errorf("valid %s: %w", input.env, err)
		}
	}
	for _, candidate := range []string{"/tmp/.emisar/data", "/tmp/.../data", "/tmp/emisar../data"} {
		result := h.functions(installer, []string{"reject_dir", "require_owned_dir"},
			`require_owned_dir TEST_DIR "$CANDIDATE"`+"\n", map[string]string{"CANDIDATE": candidate})
		if _, err := requireOutput(result); err != nil {
			return fmt.Errorf("valid near-miss %q: %w", candidate, err)
		}
	}

	validRoot := h.path("owned-dir-validation", "valid-uninstall")
	validBin := filepath.Join(validRoot, "bin")
	validEtc := filepath.Join(validRoot, "etc")
	validData := filepath.Join(validRoot, "data")
	validLog := filepath.Join(validRoot, "log")
	fakeRootBin := h.path("owned-dir-validation", "root-bin")
	if err := h.mkdir(validBin, validEtc, validData, validLog, fakeRootBin); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(fakeRootBin, "id"), `
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exit 1
`); err != nil {
		return err
	}
	for path, contents := range map[string]string{
		filepath.Join(validBin, "emisar"):                  "installed binary\n",
		filepath.Join(validBin, ".emisar-install-receipt"): filepath.Join(validEtc, "install-receipt") + "\n",
		filepath.Join(validEtc, "install-receipt"):         "schema=1\n",
		filepath.Join(validData, "token"):                  "cached token\n",
	} {
		if err := writeFile(path, contents, 0o600); err != nil {
			return err
		}
	}
	validResult := h.command(h.root, map[string]string{
		"PATH": fakeRootBin + string(os.PathListSeparator) + os.Getenv("PATH"),
	}, "bash", installer, "--yes", "--no-service", "--uninstall", "--purge",
		"--bin-dir", validBin, "--etc-dir", validEtc, "--data-dir", validData, "--log-dir", validLog)
	if output, err := requireOutput(validResult); err != nil {
		return fmt.Errorf("valid custom uninstall: %w", err)
	} else if !strings.Contains(string(output), "uninstalled") {
		return fmt.Errorf("valid custom uninstall did not finish:\n%s", output)
	}
	for _, path := range []string{filepath.Join(validBin, "emisar"), validEtc, validData, validLog} {
		if err := requireAbsent(path); err != nil {
			return fmt.Errorf("valid custom uninstall: %w", err)
		}
	}
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
	if err := exactFile(filepath.Join(data, "token.json"), "old-token-json\n"); err != nil {
		return err
	}

	restoreFailure := h.functions(installer, []string{"restore_enrollment_state"}, `
warn() { printf '%s\n' "$*" >&2; }
cp() { return 71; }
ENROLLMENT_STATE_BACKED_UP=1
tmp="$BACKUP_DIR"
restore_enrollment_state
`, map[string]string{"ETC_DIR": etc, "DATA_DIR": data, "BACKUP_DIR": backup})
	if err := expectFailure(restoreFailure, "could not restore"); err != nil {
		return fmt.Errorf("enrollment restore copy failure did not fail closed: %w", err)
	}
	return nil
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
		"--version", "runner-v"+version,
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
		"EMISAR_PACKS":             "",
		"EMISAR_RUNNER_LABEL_ROLE": "invalid label",
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

// runnerDispatchStateRollback proves pre-start failure remains reversible while
// a binary that may have executed is never replaced by an older reader. These
// cases extract the installer's real transaction helpers; only systemd and the
// two binaries are deterministic fakes.
func runnerDispatchStateRollback(h *harness) error {
	installer := h.repoPath("install.sh")
	names := []string{
		"cleanup_staged_binary",
		"rollback_binary",
		"quiesce_attempted_service",
		"restore_previous_service",
		"finish_install",
	}
	journal := `{"format":"emisar_dispatch_log","version":2}` + "\n"

	runRollback := func(name string, startAttempted bool, init string) (string, string, string, string, error) {
		root := h.path("dispatch-rollback-" + name)
		bin := filepath.Join(root, "bin")
		data := filepath.Join(root, "data")
		if err := h.mkdir(bin, data); err != nil {
			return "", "", "", "", err
		}
		target := filepath.Join(bin, "emisar")
		backup := filepath.Join(bin, ".emisar.previous")
		trace := filepath.Join(root, "trace")
		if err := writeFile(target, "new runner\n", 0o755); err != nil {
			return "", "", "", "", err
		}
		if err := writeFile(backup, "old runner\n", 0o755); err != nil {
			return "", "", "", "", err
		}
		journalPath := filepath.Join(data, "dispatches.jsonl")
		if err := writeFile(journalPath, journal, 0o600); err != nil {
			return "", "", "", "", err
		}
		before, err := fileSHA(journalPath)
		if err != nil {
			return "", "", "", "", err
		}
		attempted := "0"
		if startAttempted {
			attempted = "1"
		}
		result := h.functions(installer, names, `
warn() { printf 'WARN: %s\n' "$*" >&2; }
log() { printf 'LOG: %s\n' "$*"; }
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
sleep() { :; }
systemctl() {
  printf 'systemctl %s\n' "$*" >>"$TRACE"
  case "$*" in
    "stop emisar.service") SERVICE_STATE=inactive; return 0 ;;
    "start emisar.service") SERVICE_STATE=active; return 0 ;;
    "is-active emisar.service") printf '%s\n' "$SERVICE_STATE"; [ "$SERVICE_STATE" = active ] ;;
    *) return 0 ;;
  esac
}
SERVICE_STATE=active
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED="$START_ATTEMPTED"
STAGED_BINARY=""
BACKUP_BINARY="$BACKUP"
BIN_DIR="$BIN"
DATA_DIR="$DATA"
INIT="$INIT_VALUE"
tmp=""
finish_install 23
`, map[string]string{
			"BACKUP": backup, "BIN": bin, "DATA": data, "TRACE": trace,
			"START_ATTEMPTED": attempted, "INIT_VALUE": init,
		})
		if code := exitCode(result.err); code != 23 {
			return "", "", "", "", fmt.Errorf("%s rollback exit = %d, want 23\n%s", name, code, result.output)
		}
		after, err := fileSHA(journalPath)
		if err != nil {
			return "", "", "", "", err
		}
		if before != after {
			return "", "", "", "", fmt.Errorf("%s rollback changed the dispatch journal", name)
		}
		traceBytes, err := os.ReadFile(trace)
		if err != nil && !os.IsNotExist(err) {
			return "", "", "", "", err
		}
		return target, backup, string(result.output), string(traceBytes), nil
	}

	preStartTarget, preStartBackup, preStartOutput, _, err := runRollback("before-start", false, "systemd")
	if err != nil {
		return err
	}
	if err := exactFile(preStartTarget, "old runner\n"); err != nil {
		return fmt.Errorf("pre-start rollback did not restore the old binary: %w", err)
	}
	if err := requireAbsent(preStartBackup); err != nil {
		return fmt.Errorf("pre-start rollback left its backup: %w", err)
	}
	if strings.Contains(preStartOutput, "automatic rollback was refused") {
		return fmt.Errorf("pre-start failure unnecessarily refused rollback:\n%s", preStartOutput)
	}

	postStartTarget, postStartBackup, postStartOutput, postStartTrace, err := runRollback("after-start", true, "systemd")
	if err != nil {
		return err
	}
	if err := exactFile(postStartTarget, "new runner\n"); err != nil {
		return fmt.Errorf("post-start failure replaced the activated binary: %w", err)
	}
	if err := exactFile(postStartBackup, "old runner\n"); err != nil {
		return fmt.Errorf("post-start failure removed the recovery binary: %w", err)
	}
	if !strings.Contains(postStartOutput, "activated runner may already have advanced durable state") {
		return fmt.Errorf("post-start failure omitted the recovery boundary:\n%s", postStartOutput)
	}
	if !strings.Contains(postStartTrace, "systemctl stop emisar.service") ||
		strings.Contains(postStartTrace, "systemctl start emisar.service") {
		return fmt.Errorf("post-start recovery did not leave the service stopped:\n%s", postStartTrace)
	}

	externalTarget, externalBackup, externalOutput, externalTrace, err := runRollback("external", false, "none")
	if err != nil {
		return err
	}
	if err := exactFile(externalTarget, "new runner\n"); err != nil {
		return fmt.Errorf("externally supervised failure replaced the activated binary: %w", err)
	}
	if err := exactFile(externalBackup, "old runner\n"); err != nil {
		return fmt.Errorf("externally supervised failure removed its recovery binary: %w", err)
	}
	if !strings.Contains(externalOutput, "activated runner may already have advanced durable state") {
		return fmt.Errorf("externally supervised failure omitted its recovery boundary:\n%s", externalOutput)
	}
	if externalTrace != "" {
		return fmt.Errorf("externally supervised failure unexpectedly invoked a service manager:\n%s", externalTrace)
	}

	// If activation fails after moving the old target aside, rollback follows
	// the backup rather than a flag assignment that may not have happened yet.
	activationRoot := h.path("dispatch-rollback-activation-seam")
	activationBin := filepath.Join(activationRoot, "bin")
	activationFakeBin := filepath.Join(activationRoot, "fake-bin")
	if err := h.mkdir(activationBin, activationFakeBin); err != nil {
		return err
	}
	activationTarget := filepath.Join(activationBin, "emisar")
	activationStaged := filepath.Join(activationBin, ".emisar.new")
	activationCalls := filepath.Join(activationRoot, "mv-calls")
	activationStaleRecord := filepath.Join(activationRoot, "stale-path")
	if err := writeFile(activationTarget, "old runner\n", 0o755); err != nil {
		return err
	}
	if err := writeFile(activationStaged, "new runner\n", 0o755); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(activationFakeBin, "mv"), `
count=0
[ ! -f "$MV_CALLS" ] || count=$(cat "$MV_CALLS")
count=$((count + 1))
printf '%s\n' "$count" >"$MV_CALLS"
if [ "$count" = 2 ]; then exit 71; fi
exec /bin/mv "$@"
`); err != nil {
		return err
	}
	activationResult := h.functions(installer, []string{
		"activate_binary", "cleanup_staged_binary", "rollback_binary",
		"quiesce_attempted_service",
		"restore_previous_service", "finish_install",
	}, `
warn() { printf 'WARN: %s\n' "$*" >&2; }
log() { printf 'LOG: %s\n' "$*"; }
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=0
SERVICE_WAS_RUNNING=0
SERVICE_START_ATTEMPTED=0
STAGED_BINARY="$STAGED"
BACKUP_BINARY=""
BIN_DIR="$BIN"
DATA_DIR="$DATA"
INIT=none
tmp=""
stale="${BIN_DIR}/.emisar.previous.$$"
printf 'stale backup\n' >"$stale"
printf '%s\n' "$stale" >"$STALE_RECORD"
set +e
activate_binary
rc=$?
set -e
finish_install "$rc"
`, map[string]string{
		"PATH": activationFakeBin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"BIN":  activationBin, "DATA": activationRoot, "STAGED": activationStaged,
		"MV_CALLS": activationCalls, "STALE_RECORD": activationStaleRecord,
	})
	if code := exitCode(activationResult.err); code != 1 {
		return fmt.Errorf("activation-seam rollback exit = %d, want 1\n%s", code, activationResult.output)
	}
	if err := exactFile(activationTarget, "old runner\n"); err != nil {
		return fmt.Errorf("activation-seam rollback did not restore target: %w", err)
	}
	if err := requireAbsent(activationStaged); err != nil {
		return fmt.Errorf("activation-seam rollback left staged binary: %w", err)
	}
	stalePathBytes, err := os.ReadFile(activationStaleRecord)
	if err != nil {
		return err
	}
	if err := exactFile(strings.TrimSpace(string(stalePathBytes)), "stale backup\n"); err != nil {
		return fmt.Errorf("activation reused a predictable stale backup path: %w", err)
	}

	// On a fresh externally supervised install, an mv that completed but
	// returned failure is ambiguous. Preserve the activated target because an
	// external process may already have executed it.
	freshRoot := h.path("dispatch-rollback-fresh-activation-seam")
	freshBin := filepath.Join(freshRoot, "bin")
	freshFakeBin := filepath.Join(freshRoot, "fake-bin")
	if err := h.mkdir(freshBin, freshFakeBin); err != nil {
		return err
	}
	freshTarget := filepath.Join(freshBin, "emisar")
	freshStaged := filepath.Join(freshBin, ".emisar.new")
	if err := writeFile(freshStaged, "new runner\n", 0o755); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(freshFakeBin, "mv"), `/bin/mv "$@"
exit 71`); err != nil {
		return err
	}
	freshResult := h.functions(installer, []string{
		"activate_binary", "cleanup_staged_binary", "rollback_binary",
		"quiesce_attempted_service",
		"restore_previous_service", "finish_install",
	}, `
warn() { printf 'WARN: %s\n' "$*" >&2; }
log() { :; }
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=0
SERVICE_WAS_RUNNING=0
SERVICE_START_ATTEMPTED=0
STAGED_BINARY="$STAGED"
BACKUP_BINARY=""
BIN_DIR="$BIN"
DATA_DIR="$DATA"
INIT=none
tmp=""
set +e
activate_binary
rc=$?
set -e
finish_install "$rc"
`, map[string]string{
		"PATH": freshFakeBin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"BIN":  freshBin, "DATA": freshRoot, "STAGED": freshStaged,
	})
	if code := exitCode(freshResult.err); code != 1 {
		return fmt.Errorf("fresh activation-seam rollback exit = %d, want 1\n%s", code, freshResult.output)
	}
	if err := exactFile(freshTarget, "new runner\n"); err != nil {
		return fmt.Errorf("fresh activation seam discarded a possibly executed target: %w", err)
	}
	if !strings.Contains(string(freshResult.output), "activated runner may already have advanced durable state") {
		return fmt.Errorf("fresh activation seam omitted the recovery boundary:\n%s", freshResult.output)
	}

	// A failed restore never clears the backup, restarts the service, or claims
	// success. The operator retains both exact binary choices for recovery.
	mvRoot := h.path("dispatch-rollback-mv-failure")
	mvBin := filepath.Join(mvRoot, "bin")
	mvData := filepath.Join(mvRoot, "data")
	mvFakeBin := filepath.Join(mvRoot, "fake-bin")
	if err := h.mkdir(mvBin, mvData, mvFakeBin); err != nil {
		return err
	}
	mvTarget := filepath.Join(mvBin, "emisar")
	mvBackup := filepath.Join(mvBin, ".emisar.previous")
	mvTrace := filepath.Join(mvRoot, "trace")
	if err := writeFile(mvTarget, "new runner\n", 0o755); err != nil {
		return err
	}
	if err := fakeExecutable(mvBackup, `
if [ "$1 $2" = "state --help" ]; then printf '  check-dispatch-log\n'; exit 0; fi
if [ "$1 $2" = "state check-dispatch-log" ]; then exit 0; fi
exit 2
`); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(mvData, "dispatches.jsonl"), journal, 0o600); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(mvFakeBin, "mv"), `exit 72`); err != nil {
		return err
	}
	mvResult := h.functions(installer, names, `
warn() { printf 'WARN: %s\n' "$*" >&2; }
log() { :; }
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
sleep() { :; }
systemctl() {
  printf 'systemctl %s\n' "$*" >>"$TRACE"
  case "$*" in
    "stop emisar.service") return 0 ;;
    "is-active emisar.service") printf 'inactive\n'; return 3 ;;
    *) return 0 ;;
  esac
}
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED=0
STAGED_BINARY=""
BACKUP_BINARY="$BACKUP"
BIN_DIR="$BIN"
DATA_DIR="$DATA"
INIT=systemd
tmp=""
finish_install 23
`, map[string]string{
		"PATH":   mvFakeBin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"BACKUP": mvBackup, "BIN": mvBin, "DATA": mvData, "TRACE": mvTrace,
	})
	if code := exitCode(mvResult.err); code != 23 {
		return fmt.Errorf("failed-restore exit = %d, want 23\n%s", code, mvResult.output)
	}
	if err := exactFile(mvTarget, "new runner\n"); err != nil {
		return fmt.Errorf("failed restore changed target: %w", err)
	}
	if err := requireRegular(mvBackup); err != nil {
		return fmt.Errorf("failed restore lost backup: %w", err)
	}
	if !strings.Contains(string(mvResult.output), "binary could not be rolled back") {
		return fmt.Errorf("failed restore output is misleading:\n%s", mvResult.output)
	}
	if trace, _ := os.ReadFile(mvTrace); strings.Contains(string(trace), "systemctl start") {
		return fmt.Errorf("failed restore restarted the service:\n%s", trace)
	}

	// Once the receipt commits, the EXIT trap owns only an unactivated staging
	// temp. A signal between transaction commit and backup cleanup keeps target.
	commitRoot := h.path("dispatch-rollback-committed")
	commitBin := filepath.Join(commitRoot, "bin")
	if err := h.mkdir(commitBin); err != nil {
		return err
	}
	commitTarget := filepath.Join(commitBin, "emisar")
	commitBackup := filepath.Join(commitBin, ".emisar.previous")
	if err := writeFile(commitTarget, "new runner\n", 0o755); err != nil {
		return err
	}
	if err := writeFile(commitBackup, "old runner\n", 0o755); err != nil {
		return err
	}
	commitResult := h.functions(installer, []string{"cleanup_staged_binary", "finish_install"}, `
warn() { :; }
INSTALL_TRANSACTION=0
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED=1
STAGED_BINARY=""
BACKUP_BINARY="$BACKUP"
tmp=""
finish_install 23
`, map[string]string{"BACKUP": commitBackup})
	if code := exitCode(commitResult.err); code != 23 {
		return fmt.Errorf("committed cleanup exit = %d, want 23\n%s", code, commitResult.output)
	}
	if err := exactFile(commitTarget, "new runner\n"); err != nil {
		return fmt.Errorf("committed cleanup removed activated target: %w", err)
	}
	if err := exactFile(commitBackup, "old runner\n"); err != nil {
		return fmt.Errorf("committed cleanup unexpectedly swapped backup: %w", err)
	}

	if err := runnerServiceStopBoundaries(h, installer); err != nil {
		return err
	}
	if err := runnerUpgradeArtifactRollback(h, installer); err != nil {
		return err
	}

	// A downgrade binary without the offline reader is rejected whenever the
	// host already has durable state; absence remains valid for a first install.
	noCheck := h.path("staged-without-state-check")
	if err := fakeExecutable(noCheck, `
if [ "$1 $2" = "state --help" ]; then printf 'state commands\n'; exit 0; fi
exit 2
`); err != nil {
		return err
	}
	stateDir := h.path("staged-state")
	if err := h.mkdir(stateDir); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(stateDir, "dispatches.jsonl"), journal, 0o600); err != nil {
		return err
	}
	preflight := h.functions(installer, []string{"runner_installation_present", "check_dispatch_log"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
check_dispatch_log
`, map[string]string{"STAGED_BINARY": noCheck, "DATA_DIR": stateDir})
	if err := expectFailure(preflight, "cannot verify the existing durable dispatch state"); err != nil {
		return fmt.Errorf("staged binary without the state reader was accepted: %w", err)
	}

	existingDir := h.path("staged-existing-without-state")
	existingBin := filepath.Join(existingDir, "bin")
	existingData := filepath.Join(existingDir, "data")
	if err := h.mkdir(existingBin, existingData); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(existingBin, "emisar"), "old runner\n", 0o755); err != nil {
		return err
	}
	existingPreflight := h.functions(installer,
		[]string{"runner_installation_present", "check_dispatch_log"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
check_dispatch_log
`, map[string]string{
			"STAGED_BINARY": noCheck, "DATA_DIR": existingData, "BIN_DIR": existingBin,
		})
	if err := expectFailure(existingPreflight, "cannot verify the existing durable dispatch state"); err != nil {
		return fmt.Errorf("existing no-state installation accepted a target without the reader: %w", err)
	}

	serviceMarker := filepath.Join(existingDir, "emisar.service")
	if err := writeFile(serviceMarker, "unit\n", 0o644); err != nil {
		return err
	}
	markerCheck := h.functions(installer, []string{"runner_installation_present"}, `
BIN_DIR=""
INSTALL_RECEIPT_PATH=""
INSTALL_RECEIPT_LOCATOR=""
DATA_DIR="$DATA_DIR"
runner_installation_present "$SYSTEMD_MARKER" "$LAUNCHD_MARKER"
`, map[string]string{
		"DATA_DIR":       existingData,
		"SYSTEMD_MARKER": serviceMarker,
		"LAUNCHD_MARKER": filepath.Join(existingDir, "missing.plist"),
	})
	if _, err := requireOutput(markerCheck); err != nil {
		return fmt.Errorf("service marker was not treated as an existing installation: %w", err)
	}

	return nil
}

func runnerUpgradeArtifactRollback(h *harness, installer string) error {
	root := h.path("upgrade-artifact-rollback")
	backup := filepath.Join(root, "backup")
	regular := filepath.Join(root, "install-receipt")
	locator := filepath.Join(root, "receipt-locator")
	absent := filepath.Join(root, "new-wrapper")
	oldLinkTarget := filepath.Join(root, "old-locator-target")
	newLinkTarget := filepath.Join(root, "new-locator-target")
	if err := h.mkdir(root, backup); err != nil {
		return err
	}
	if err := writeFile(regular, "old receipt\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(oldLinkTarget, "old locator target\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(newLinkTarget, "new locator target\n", 0o600); err != nil {
		return err
	}
	if err := os.Symlink(oldLinkTarget, locator); err != nil {
		return err
	}

	result := h.functions(installer,
		[]string{"snapshot_install_artifact", "restore_install_artifact"}, `
snapshot_install_artifact "$REGULAR" receipt "$BACKUP"
snapshot_install_artifact "$LOCATOR" receipt-locator "$BACKUP"
snapshot_install_artifact "$ABSENT" launchd-runner "$BACKUP"
printf 'new receipt\n' >"$REGULAR"
chmod 0644 "$REGULAR"
rm -f "$LOCATOR"
ln -s "$NEW_LINK_TARGET" "$LOCATOR"
printf 'new wrapper\n' >"$ABSENT"
INSTALL_STATE_BACKUP="$BACKUP"
restore_install_artifact "$REGULAR" receipt
restore_install_artifact "$LOCATOR" receipt-locator
restore_install_artifact "$ABSENT" launchd-runner
`, map[string]string{
			"BACKUP": backup, "REGULAR": regular, "LOCATOR": locator, "ABSENT": absent,
			"NEW_LINK_TARGET": newLinkTarget,
		})
	if _, err := requireOutput(result); err != nil {
		return fmt.Errorf("restore exact installer artifacts: %w", err)
	}
	if err := exactFile(regular, "old receipt\n"); err != nil {
		return err
	}
	if info, err := os.Stat(regular); err != nil || info.Mode().Perm() != 0o600 {
		return fmt.Errorf("restored receipt mode = %v err=%v, want 0600", info, err)
	}
	if target, err := os.Readlink(locator); err != nil || target != oldLinkTarget {
		return fmt.Errorf("restored locator link = %q err=%v, want %q", target, err, oldLinkTarget)
	}
	if err := requireAbsent(absent); err != nil {
		return fmt.Errorf("originally absent artifact survived rollback: %w", err)
	}

	wiringTrace := filepath.Join(root, "artifact-wiring")
	wired := h.functions(installer, []string{"rollback_service", "rollback_install_receipt"}, `
log() { :; }
restore_install_artifact() { printf 'restore %s %s\n' "$1" "$2" >>"$TRACE"; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$TRACE"; }
launchctl() { printf 'launchctl %s\n' "$*" >>"$TRACE"; }
INSTALL_STATE_BACKUP=/trusted-backup
SERVICE_UNIT_CREATED=0
ETC_DIR=/etc/emisar
INSTALL_RECEIPT_PATH=/etc/emisar/install-receipt
INSTALL_RECEIPT_LOCATOR=/usr/local/bin/.emisar-install-receipt
INIT=systemd
rollback_service
INIT=launchd
rollback_service
rollback_install_receipt
`, map[string]string{"TRACE": wiringTrace})
	if _, err := requireOutput(wired); err != nil {
		return fmt.Errorf("installer artifact rollback wiring: %w", err)
	}
	for _, want := range []string{
		"restore /etc/systemd/system/emisar.service systemd-unit\n",
		"systemctl daemon-reload\n",
		"restore /Library/LaunchDaemons/com.emisar.runner.plist launchd-plist\n",
		"restore /etc/emisar/run-launchd.sh launchd-runner\n",
		"restore /etc/emisar/install-receipt receipt\n",
		"restore /usr/local/bin/.emisar-install-receipt receipt-locator\n",
	} {
		if err := containsFile(wiringTrace, want); err != nil {
			return fmt.Errorf("installer artifact rollback wiring: %w", err)
		}
	}
	disableBackup := filepath.Join(root, "disable-failure-backup")
	if err := h.mkdir(disableBackup); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(disableBackup, "systemd-unit.absent"), "\n", 0o600); err != nil {
		return err
	}
	disableTrace := filepath.Join(root, "disable-failure-trace")
	disableFailure := h.functions(installer, []string{"rollback_service"}, `
log() { :; }
restore_install_artifact() { printf 'restore\n' >>"$TRACE"; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$TRACE"; return 71; }
INSTALL_STATE_BACKUP="$BACKUP"
SERVICE_UNIT_CREATED=0
INIT=systemd
rollback_service
`, map[string]string{"TRACE": disableTrace, "BACKUP": disableBackup})
	if err := expectFailure(disableFailure, ""); err != nil {
		return fmt.Errorf("failed systemd disable did not fail rollback: %w", err)
	}
	disableTraceBytes, err := os.ReadFile(disableTrace)
	if err != nil {
		return err
	}
	if strings.Contains(string(disableTraceBytes), "restore\n") {
		return fmt.Errorf("failed systemd disable continued into artifact replacement:\n%s", disableTraceBytes)
	}

	trace := filepath.Join(root, "restore-order")
	transactionTmp := filepath.Join(root, "transaction-success")
	if err := h.mkdir(transactionTmp); err != nil {
		return err
	}
	ordered := h.functions(installer, []string{"finish_install"}, `
warn() { :; }
quiesce_attempted_service() { printf 'quiesce\n' >>"$TRACE"; }
rollback_binary() { printf 'binary\n' >>"$TRACE"; }
restore_enrollment_state() { printf 'enrollment\n' >>"$TRACE"; }
rollback_service() { printf 'service-files\n' >>"$TRACE"; }
rollback_install_receipt() { printf 'receipt-files\n' >>"$TRACE"; }
restore_previous_service() { printf 'service-start\n' >>"$TRACE"; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED=0
INIT=systemd
STAGED_BINARY=""
BACKUP_BINARY=""
PRESERVE_INSTALL_BACKUP=0
tmp="$TRANSACTION_TMP"
finish_install 23
`, map[string]string{"TRACE": trace, "TRANSACTION_TMP": transactionTmp})
	if code := exitCode(ordered.err); code != 23 {
		return fmt.Errorf("artifact restore ordering exit = %d, want 23\n%s", code, ordered.output)
	}
	if err := exactFile(trace, "quiesce\nbinary\nenrollment\nservice-files\nreceipt-files\nservice-start\n"); err != nil {
		return fmt.Errorf("artifact restore ordering: %w", err)
	}

	failureTrace := filepath.Join(root, "restore-failure-order")
	failureTmp := filepath.Join(root, "transaction-failure")
	if err := h.mkdir(failureTmp); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(failureTmp, "prior-state"), "keep\n", 0o600); err != nil {
		return err
	}
	failed := h.functions(installer, []string{"finish_install"}, `
warn() { printf 'WARN: %s\n' "$*" >&2; }
quiesce_attempted_service() { :; }
rollback_binary() { :; }
restore_enrollment_state() { :; }
rollback_service() { printf 'service-files\n' >>"$TRACE"; return 1; }
rollback_install_receipt() { printf 'receipt-files\n' >>"$TRACE"; }
restore_previous_service() { printf 'service-start\n' >>"$TRACE"; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED=0
INIT=systemd
STAGED_BINARY=""
BACKUP_BINARY=""
PRESERVE_INSTALL_BACKUP=0
tmp="$TRANSACTION_TMP"
finish_install 23
`, map[string]string{"TRACE": failureTrace, "TRANSACTION_TMP": failureTmp})
	if code := exitCode(failed.err); code != 23 {
		return fmt.Errorf("artifact restore failure exit = %d, want 23\n%s", code, failed.output)
	}
	if traceBytes, err := os.ReadFile(failureTrace); err != nil || strings.Contains(string(traceBytes), "service-start") {
		return fmt.Errorf("artifact restore failure restarted service: trace=%q err=%v", traceBytes, err)
	}
	if err := exactFile(filepath.Join(failureTmp, "prior-state"), "keep\n"); err != nil {
		return fmt.Errorf("artifact restore failure discarded recovery state: %w", err)
	}
	if !strings.Contains(string(failed.output), "rollback files were kept") {
		return fmt.Errorf("artifact restore failure omitted recovery path:\n%s", failed.output)
	}

	signalTrace := filepath.Join(root, "rollback-signal-critical-section")
	signalResult := h.functions(installer, []string{"finish_install"}, `
warn() { :; }
quiesce_attempted_service() { :; }
rollback_binary() {
  printf 'before-signal\n' >>"$TRACE"
  kill -TERM $$
  printf 'after-signal\n' >>"$TRACE"
}
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
restore_previous_service() { :; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=0
SERVICE_START_ATTEMPTED=0
INIT=systemd
STAGED_BINARY=""
BACKUP_BINARY=""
PRESERVE_INSTALL_BACKUP=0
tmp=""
finish_install 23
`, map[string]string{"TRACE": signalTrace})
	if code := exitCode(signalResult.err); code != 23 {
		return fmt.Errorf("signal during rollback exit = %d, want original 23\n%s", code, signalResult.output)
	}
	if err := exactFile(signalTrace, "before-signal\nafter-signal\n"); err != nil {
		return fmt.Errorf("signal interrupted rollback critical section: %w", err)
	}

	authFailureTrace := filepath.Join(root, "authentication-restore-failure")
	authFailureTmp := filepath.Join(root, "authentication-restore-failure-tmp")
	if err := h.mkdir(authFailureTmp); err != nil {
		return err
	}
	authFailed := h.functions(installer, []string{"finish_install"}, `
warn() { :; }
quiesce_attempted_service() { :; }
rollback_binary() { :; }
restore_enrollment_state() { printf 'authentication\n' >>"$TRACE"; return 1; }
rollback_service() { printf 'service\n' >>"$TRACE"; }
rollback_install_receipt() { printf 'receipt\n' >>"$TRACE"; }
restore_previous_service() { printf 'start\n' >>"$TRACE"; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=1
SERVICE_WAS_RUNNING=1
SERVICE_START_ATTEMPTED=0
INIT=systemd
STAGED_BINARY=""
BACKUP_BINARY=""
PRESERVE_INSTALL_BACKUP=0
tmp="$TRANSACTION_TMP"
finish_install 23
`, map[string]string{"TRACE": authFailureTrace, "TRANSACTION_TMP": authFailureTmp})
	if code := exitCode(authFailed.err); code != 23 {
		return fmt.Errorf("authentication restore failure exit = %d, want 23\n%s", code, authFailed.output)
	}
	if err := exactFile(authFailureTrace, "authentication\n"); err != nil {
		return fmt.Errorf("authentication restore failure continued into service restart: %w", err)
	}
	if _, err := os.Stat(authFailureTmp); err != nil {
		return fmt.Errorf("authentication restore failure discarded recovery state: %v", err)
	}

	if err := runnerInstallMappingBoundary(h, installer); err != nil {
		return err
	}
	return runnerDispatchQuarantineBoundary(h, installer)
}

func runnerInstallMappingBoundary(h *harness, installer string) error {
	root := h.path("install-mapping-boundary")
	bin := filepath.Join(root, "bin")
	etc := filepath.Join(root, "etc")
	data := filepath.Join(root, "data")
	logs := filepath.Join(root, "logs")
	if err := h.mkdir(bin, etc, data, logs); err != nil {
		return err
	}
	target := filepath.Join(bin, "emisar")
	receipt := filepath.Join(etc, "install-receipt")
	locator := filepath.Join(bin, ".emisar-install-receipt")
	if err := writeFile(target, "runner\n", 0o755); err != nil {
		return err
	}
	receiptBody := "schema=1\nmanager=install.sh\nrepository=AndrewDryga/emisar\n" +
		"binary=" + target + "\n" +
		"etc_dir=" + etc + "\n" +
		"data_dir=" + data + "\n" +
		"log_dir=" + logs + "\n" +
		"service_user=emisar\nservice_group=emisar\ninit=systemd\n"
	if err := writeFile(receipt, receiptBody, 0o600); err != nil {
		return err
	}
	if err := writeFile(locator, receipt+"\n", 0o644); err != nil {
		return err
	}
	run := func(repository, dataDir string) commandResult {
		return h.functions(installer,
			[]string{"receipt_field_equals", "receipt_repository_equals", "verify_existing_install_mapping"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
trusted_install_path() { :; }
verify_managed_service_mapping() { :; }
verify_existing_install_mapping
`, map[string]string{
				"OS": "linux", "REPO": repository, "OFFICIAL_REPO": "andrewdryga/emisar", "SUCCESSOR_REPO": "emisarhq/emisar",
				"BIN_DIR": bin, "ETC_DIR": etc, "DATA_DIR": dataDir,
				"LOG_DIR": logs, "SERVICE_USER": "emisar", "SERVICE_GROUP": "emisar", "INIT": "systemd",
				"INSTALL_RECEIPT_PATH": receipt, "INSTALL_RECEIPT_LOCATOR": locator,
			})
	}
	if _, err := requireOutput(run("andrewdryga/emisar", data)); err != nil {
		return fmt.Errorf("unchanged install mapping rejected: %w", err)
	}
	if _, err := requireOutput(run("emisarhq/emisar", data)); err != nil {
		return fmt.Errorf("official repository transfer mapping rejected: %w", err)
	}
	if err := expectFailure(run("andrewdryga/emisar", filepath.Join(root, "other-data")), "cannot be changed in place"); err != nil {
		return fmt.Errorf("changed data directory was accepted: %w", err)
	}
	if err := os.Remove(receipt); err != nil {
		return err
	}
	if err := os.Remove(locator); err != nil {
		return err
	}
	if err := expectFailure(run("andrewdryga/emisar", data), "has no install receipt"); err != nil {
		return fmt.Errorf("receiptless existing runner was accepted: %w", err)
	}

	unit := filepath.Join(root, "emisar.service")
	validUnit := "User=emisar\nGroup=emisar\nExecStart=" + target + " --config " + etc + "/config.yaml connect\n"
	if err := writeFile(unit, validUnit, 0o644); err != nil {
		return err
	}
	verifyService := func(dropins string) commandResult {
		return h.functions(installer,
			[]string{"file_has_exact_line_once", "file_has_single_assignment", "verify_managed_service_mapping"}, `
systemctl() {
  case "$*" in
    "show emisar.service --property=FragmentPath --value") printf '%s\n' "$UNIT" ;;
    "show emisar.service --property=DropInPaths --value") printf '%s\n' "$DROPINS" ;;
    *) return 1 ;;
  esac
}
INIT=systemd
verify_managed_service_mapping "$UNIT" "$MISSING" "$MISSING"
`, map[string]string{
				"UNIT": unit, "DROPINS": dropins, "MISSING": filepath.Join(root, "missing"),
				"BIN_DIR": bin, "ETC_DIR": etc, "SERVICE_USER": "emisar", "SERVICE_GROUP": "emisar",
			})
	}
	if _, err := requireOutput(verifyService("")); err != nil {
		return fmt.Errorf("canonical systemd mapping rejected: %w", err)
	}
	if err := writeFile(unit, strings.Replace(validUnit, etc+"/config.yaml", root+"/other.yaml", 1), 0o644); err != nil {
		return err
	}
	if err := expectFailure(verifyService(""), ""); err != nil {
		return fmt.Errorf("altered systemd config path was accepted: %w", err)
	}
	if err := writeFile(unit, validUnit, 0o644); err != nil {
		return err
	}
	if err := expectFailure(verifyService("/etc/systemd/system/emisar.service.d/override.conf"), ""); err != nil {
		return fmt.Errorf("systemd drop-in was accepted as canonical mapping: %w", err)
	}

	plist := filepath.Join(root, "com.emisar.runner.plist")
	wrapper := filepath.Join(etc, "run-launchd.sh")
	if err := writeFile(plist, "plist fixture\n", 0o644); err != nil {
		return err
	}
	verifyLaunchd := func(configPath string, tamperWrapper bool) commandResult {
		return h.functions(installer,
			[]string{"launchd_runner_script", "file_has_exact_line_once", "file_has_single_assignment", "verify_managed_service_mapping"}, `
launchctl() {
  case "$1 $2" in
    "print system") return 0 ;;
    "print system/com.emisar.runner") printf 'path = %s\n' "$PLIST" ;;
    *) return 1 ;;
  esac
}
plutil() {
  case "$2" in
    ProgramArguments) printf '4\n' ;;
    ProgramArguments.0) printf '%s/run-launchd.sh\n' "$ETC_DIR" ;;
    ProgramArguments.1) printf '%s/emisar\n' "$BIN_DIR" ;;
    ProgramArguments.2) printf '%s\n' "$CONFIG_PATH" ;;
    ProgramArguments.3) printf '%s/runner.env\n' "$ETC_DIR" ;;
    WorkingDirectory) printf '%s\n' "$DATA_DIR" ;;
    *) return 1 ;;
  esac
}
launchd_runner_script >"$WRAPPER"
if [ "$TAMPER" = 1 ]; then printf 'echo tampered\n' >>"$WRAPPER"; fi
INIT=launchd
verify_managed_service_mapping "$MISSING" "$PLIST" "$WRAPPER"
`, map[string]string{
				"PLIST": plist, "WRAPPER": wrapper, "MISSING": filepath.Join(root, "missing"),
				"BIN_DIR": bin, "ETC_DIR": etc, "DATA_DIR": data,
				"CONFIG_PATH": configPath, "TAMPER": map[bool]string{true: "1", false: "0"}[tamperWrapper],
			})
	}
	if _, err := requireOutput(verifyLaunchd(filepath.Join(etc, "config.yaml"), false)); err != nil {
		return fmt.Errorf("canonical launchd mapping rejected: %w", err)
	}
	if err := expectFailure(verifyLaunchd(filepath.Join(root, "other.yaml"), false), ""); err != nil {
		return fmt.Errorf("altered launchd config path was accepted: %w", err)
	}
	if err := expectFailure(verifyLaunchd(filepath.Join(etc, "config.yaml"), true), ""); err != nil {
		return fmt.Errorf("altered launchd wrapper was accepted: %w", err)
	}

	if err := writeFile(receipt, receiptBody, 0o600); err != nil {
		return err
	}
	trustedReceipt, err := filepath.EvalSymlinks(receipt)
	if err != nil {
		return fmt.Errorf("resolving receipt fixture: %w", err)
	}
	trustReceipt := func(owner string) commandResult {
		return h.functions(installer, []string{"path_owner_mode", "trusted_install_path"}, `
stat() {
  path="${@: -1}"
  if [ "$path" = "$RECEIPT" ]; then printf '%s:600\n' "$OWNER"; else printf '0:755\n'; fi
}
OS=linux
trusted_install_path "$RECEIPT" 600
`, map[string]string{"RECEIPT": trustedReceipt, "OWNER": owner})
	}
	if _, err := requireOutput(trustReceipt("0")); err != nil {
		return fmt.Errorf("root-owned receipt rejected: %w", err)
	}
	if err := expectFailure(trustReceipt("501"), ""); err != nil {
		return fmt.Errorf("non-root receipt was trusted: %w", err)
	}
	return nil
}

func runnerDispatchQuarantineBoundary(h *harness, installer string) error {
	root := h.path("dispatch-quarantine-boundary")
	data := filepath.Join(root, "data")
	etc := filepath.Join(root, "etc")
	if err := h.mkdir(data, etc); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(etc, "config.yaml"), "paths:\n  data_dir: "+data+"\n", 0o600); err != nil {
		return err
	}
	staged := filepath.Join(root, "staged-runner")
	if err := fakeExecutable(staged, `
if [ "$1 $2" = "state --help" ]; then
  printf '  check-dispatch-log\n'
  exit 0
fi
if [ "$3 $4" = "state check-dispatch-log" ]; then
  [ ! -e "$DATA_DIR/dispatches.jsonl" ] && [ ! -L "$DATA_DIR/dispatches.jsonl" ] &&
    [ ! -e "$DATA_DIR/dedup.jsonl" ] && [ ! -L "$DATA_DIR/dedup.jsonl" ]
  exit
fi
exit 2
`); err != nil {
		return err
	}
	current := filepath.Join(data, "dispatches.jsonl")
	legacy := filepath.Join(data, "dedup.jsonl")
	if err := writeFile(current, "corrupt current\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(legacy, "stale legacy\n", 0o600); err != nil {
		return err
	}
	quarantined := h.functions(installer, []string{"check_dispatch_log"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
DISPATCH_LOG_QUIESCED=0
check_dispatch_log pre-stop
[ -e "$DATA_DIR/dispatches.jsonl" ] && [ -e "$DATA_DIR/dedup.jsonl" ]
DISPATCH_LOG_QUIESCED=1
check_dispatch_log
`, map[string]string{
		"STAGED_BINARY": staged, "DATA_DIR": data, "ETC_DIR": etc, "QUARANTINE_DISPATCH_LOG": "1",
	})
	if _, err := requireOutput(quarantined); err != nil {
		return fmt.Errorf("quarantine after quiescence: %w", err)
	}
	if err := requireAbsent(current); err != nil {
		return err
	}
	if err := requireAbsent(legacy); err != nil {
		return err
	}
	quarantines, err := filepath.Glob(filepath.Join(root, ".emisar-dispatch-quarantine-*"))
	if err != nil || len(quarantines) != 1 {
		return fmt.Errorf("dispatch quarantine dirs = %v err=%v, want one sibling directory", quarantines, err)
	}
	quarantine := quarantines[0]
	if strings.HasPrefix(quarantine, data+string(os.PathSeparator)) {
		return fmt.Errorf("dispatch quarantine remained inside data dir: %s", quarantine)
	}
	if info, err := os.Stat(quarantine); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		return fmt.Errorf("dispatch quarantine mode = %v err=%v, want directory 0700", info, err)
	}
	if err := exactFile(filepath.Join(quarantine, "dispatches.jsonl"), "corrupt current\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(quarantine, "dedup.jsonl"), "stale legacy\n"); err != nil {
		return err
	}

	blockedData := filepath.Join(root, "not-quiesced")
	if err := h.mkdir(blockedData); err != nil {
		return err
	}
	blockedCurrent := filepath.Join(blockedData, "dispatches.jsonl")
	if err := writeFile(blockedCurrent, "corrupt\n", 0o600); err != nil {
		return err
	}
	blocked := h.functions(installer, []string{"check_dispatch_log"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
DISPATCH_LOG_QUIESCED=0
check_dispatch_log
`, map[string]string{
		"STAGED_BINARY": staged, "DATA_DIR": blockedData, "ETC_DIR": etc, "QUARANTINE_DISPATCH_LOG": "1",
	})
	if err := expectFailure(blocked, "without proving the existing service is stopped"); err != nil {
		return fmt.Errorf("unquiesced quarantine did not fail closed: %w", err)
	}
	if err := exactFile(blockedCurrent, "corrupt\n"); err != nil {
		return fmt.Errorf("unquiesced quarantine moved live state: %w", err)
	}
	return nil
}

func runnerServiceStopBoundaries(h *harness, installer string) error {
	systemdBody := func(stateAfterStop, stopStatus string) string {
		return `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
STATE=active
systemctl() {
  case "$1" in
    is-active) [ -n "$STATE" ] && printf '%s\n' "$STATE"; [ "$STATE" = active ] ;;
    stop) STATE="` + stateAfterStop + `"; return ` + stopStatus + ` ;;
  esac
}
SERVICE_WAS_RUNNING=0
DISPATCH_LOG_QUIESCED=0
stop_systemd_service_if_running
printf 'stopped=%s state=%s quiesced=%s\n' "$SERVICE_WAS_RUNNING" "$STATE" "$DISPATCH_LOG_QUIESCED"
`
	}
	success := h.functions(installer, []string{"stop_systemd_service_if_running"},
		systemdBody("inactive", "0"), nil)
	output, err := requireOutput(success)
	if err != nil {
		return fmt.Errorf("systemd stop success: %w", err)
	}
	if !strings.Contains(string(output), "stopped=1 state=inactive quiesced=1") {
		return fmt.Errorf("systemd stop did not prove the terminal state: %s", output)
	}
	stopFailure := h.functions(installer, []string{"stop_systemd_service_if_running"},
		systemdBody("active", "1"), nil)
	if err := expectFailure(stopFailure, "could not stop emisar.service for upgrade"); err != nil {
		return fmt.Errorf("systemd stop failure was accepted: %w", err)
	}
	nonterminal := h.functions(installer, []string{"stop_systemd_service_if_running"},
		systemdBody("deactivating", "0"), nil)
	if err := expectFailure(nonterminal, "did not stop cleanly"); err != nil {
		return fmt.Errorf("systemd nonterminal state was accepted: %w", err)
	}
	queryFailure := h.functions(installer, []string{"stop_systemd_service_if_running"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
systemctl() { return 1; }
SERVICE_WAS_RUNNING=0
stop_systemd_service_if_running
`, nil)
	if err := expectFailure(queryFailure, "could not determine emisar.service state"); err != nil {
		return fmt.Errorf("systemd query failure was accepted: %w", err)
	}

	quiesceQueryFailure := h.functions(installer, []string{"quiesce_attempted_service"}, `
systemctl() {
  case "$1" in stop) return 0;; is-active) return 1;; esac
}
SERVICE_START_ATTEMPTED=1
INIT=systemd
quiesce_attempted_service
`, nil)
	if err := expectFailure(quiesceQueryFailure, ""); err != nil {
		return fmt.Errorf("systemd rollback query failure was accepted: %w", err)
	}

	launchdCases := []struct {
		name string
		body string
		want string
	}{
		{
			name: "domain query failure",
			body: `launchctl() { return 1; }`,
			want: "could not query the launchd system domain",
		},
		{
			name: "bootout failure",
			body: `
launchctl() {
  case "$1 $2" in
    "print system"|"print system/com.emisar.runner") return 0 ;;
    "bootout system") return 1 ;;
  esac
}`,
			want: "could not unload com.emisar.runner",
		},
		{
			name: "label remains loaded",
			body: `
launchctl() {
  case "$1 $2" in
    "print system"|"print system/com.emisar.runner"|"bootout system") return 0 ;;
  esac
}`,
			want: "remained loaded after unload",
		},
	}
	for _, test := range launchdCases {
		result := h.functions(installer, []string{"stop_service_if_running"}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
`+test.body+`
INIT=launchd
SERVICE_WAS_RUNNING=0
stop_service_if_running
`, nil)
		if err := expectFailure(result, test.want); err != nil {
			return fmt.Errorf("launchd %s was accepted: %w", test.name, err)
		}
	}

	launchdQuiesceFailure := h.functions(installer, []string{"quiesce_attempted_service"}, `
launchctl() { return 1; }
SERVICE_START_ATTEMPTED=1
INIT=launchd
quiesce_attempted_service
`, nil)
	if err := expectFailure(launchdQuiesceFailure, ""); err != nil {
		return fmt.Errorf("launchd rollback query failure was accepted: %w", err)
	}

	// A running daemon can create its first legacy record after the early
	// staged check. The second check runs only after stop and must restore the
	// prior service without ever activating the target binary.
	raceRoot := h.path("dispatch-post-stop-recheck")
	raceBin := filepath.Join(raceRoot, "bin")
	raceData := filepath.Join(raceRoot, "data")
	raceEtc := filepath.Join(raceRoot, "etc")
	if err := h.mkdir(raceBin, raceData, raceEtc); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(raceEtc, "config.yaml"), "paths:\n  data_dir: "+raceData+"\n", 0o600); err != nil {
		return err
	}
	raceTarget := filepath.Join(raceBin, "emisar")
	raceStaged := filepath.Join(raceBin, ".emisar.new")
	raceTrace := filepath.Join(raceRoot, "trace")
	if err := writeFile(raceTarget, "old runner\n", 0o755); err != nil {
		return err
	}
	if err := fakeExecutable(raceStaged, `
if [ "$1 $2" = "state --help" ]; then printf '  check-dispatch-log\n'; exit 0; fi
if [ "$3 $4" = "state check-dispatch-log" ]; then
  [ ! -e "$DATA/dispatches.jsonl" ] && [ ! -e "$DATA/dedup.jsonl" ]
  exit
fi
exit 2
`); err != nil {
		return err
	}
	raceResult := h.functions(installer, []string{
		"runner_installation_present", "check_dispatch_log", "stop_systemd_service_if_running",
		"cleanup_staged_binary", "rollback_binary", "quiesce_attempted_service",
		"restore_previous_service", "finish_install",
	}, `
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
log() { :; }
restore_enrollment_state() { :; }
rollback_service() { :; }
rollback_install_receipt() { :; }
sleep() { :; }
STATE=active
systemctl() {
  printf 'systemctl %s\n' "$*" >>"$TRACE"
  case "$1" in
    is-active) printf '%s\n' "$STATE"; [ "$STATE" = active ] ;;
    stop) printf '{}\n' >"$DATA/dedup.jsonl"; STATE=inactive; return 0 ;;
    start) STATE=active; return 0 ;;
  esac
}
INSTALL_TRANSACTION=0
BINARY_ACTIVATED=0
SERVICE_WAS_RUNNING=0
SERVICE_START_ATTEMPTED=0
STAGED_BINARY="$STAGED"
BACKUP_BINARY=""
BIN_DIR="$BIN"
DATA_DIR="$DATA"
ETC_DIR="$ETC"
INIT=systemd
tmp=""
trap 'finish_install $?' EXIT
check_dispatch_log
INSTALL_TRANSACTION=1
stop_systemd_service_if_running
check_dispatch_log
`, map[string]string{
		"BIN": raceBin, "DATA": raceData, "ETC": raceEtc, "STAGED": raceStaged, "TRACE": raceTrace,
	})
	if err := expectFailure(raceResult, "refusing to upgrade over unreadable dispatch state"); err != nil {
		return fmt.Errorf("post-stop dispatch recheck did not fail closed: %w", err)
	}
	if err := exactFile(raceTarget, "old runner\n"); err != nil {
		return fmt.Errorf("post-stop dispatch recheck changed the target: %w", err)
	}
	trace, err := os.ReadFile(raceTrace)
	if err != nil {
		return err
	}
	stopAt := strings.Index(string(trace), "systemctl stop emisar.service")
	startAt := strings.Index(string(trace), "systemctl start emisar.service")
	if stopAt < 0 || startAt <= stopAt {
		return fmt.Errorf("post-stop dispatch recheck did not restore service order:\n%s", trace)
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
quiesce_attempted_service() { :; }
restore_enrollment_state() { :; }
restore_previous_service() { :; }
rollback_install_receipt() { :; }
rollback_service() { :; }
warn() { :; }
INSTALL_TRANSACTION=1
BINARY_ACTIVATED=0
SERVICE_WAS_RUNNING=0
SERVICE_START_ATTEMPTED=0
INIT=systemd
BACKUP_BINARY=""
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

	launchdBody := `
launchctl() { printf '%s\n' "$LAUNCHD_DETAILS"; }
require_launchd_service_running
`
	running := h.functions(h.repoPath("install.sh"), []string{"require_launchd_service_running"},
		launchdBody, map[string]string{"LAUNCHD_DETAILS": "state = running\npid = 42"})
	if _, err := requireOutput(running); err != nil {
		return fmt.Errorf("running launchd service rejected: %w", err)
	}
	for _, details := range []string{"state = exited\npid = 42", "state = running"} {
		result := h.functions(h.repoPath("install.sh"), []string{"require_launchd_service_running"},
			launchdBody, map[string]string{"LAUNCHD_DETAILS": details})
		if err := expectFailure(result, ""); err != nil {
			return fmt.Errorf("non-running launchd state %q was accepted: %w", details, err)
		}
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

// runnerLatestRelease proves the Emisar mirror wins without a GitHub request,
// while a custom repository retains the filtered GitHub fallback.
func runnerLatestRelease(h *harness) error {
	const releases = `[` +
		`{"tag_name":"runner-v0.11.0","draft":true,"prerelease":false},` +
		`{"tag_name":"runner-v0.10.1","draft":false,"prerelease":true},` +
		`{"tag_name":"runner-v0.2.9","draft":false,"prerelease":false},` +
		`{"tag_name":"runner-v0.10.0","draft":false,"prerelease":false},` +
		`{"tag_name":"runner-v0.9.9","draft":false,"prerelease":false},` +
		`{"tag_name":"mcp-v9.9.9","draft":false,"prerelease":false}]`
	const manifest = `{"schema_version":1,"component":"runner","tag":"runner-v0.12.0","version":"0.12.0","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`

	parsed := h.functions(h.repoPath("install.sh"), []string{"release_manifest_tag"}, `
curl() { printf '%s' "$MANIFEST"; }
release_manifest_tag https://example.invalid/latest.json runner
`, map[string]string{"MANIFEST": manifest})
	output, err := requireOutput(parsed)
	if err != nil {
		return fmt.Errorf("parse valid mirror manifest: %w", err)
	}
	if got := strings.TrimSpace(string(output)); got != "runner-v0.12.0" {
		return fmt.Errorf("parsed mirror tag = %q", got)
	}
	malformed := h.functions(h.repoPath("install.sh"), []string{"release_manifest_tag"}, `
curl() { printf '%s' "$MANIFEST"; }
release_manifest_tag https://example.invalid/latest.json runner || {
  status=$?
  printf 'invalid manifest status %s\n' "$status" >&2
  exit "$status"
}
`, map[string]string{"MANIFEST": strings.Replace(manifest, `"version":"0.12.0"`, `"version":"0.11.0"`, 1)})
	if err := expectFailure(malformed, "invalid manifest status 2"); err != nil {
		return fmt.Errorf("mismatched mirror manifest did not fail closed: %w", err)
	}

	result := h.functions(h.repoPath("install.sh"), []string{"resolve_latest_from_github", "resolve_latest_version"}, `
die() { printf '%s\n' "$1" >&2; exit 1; }
warn() { :; }
release_manifest_tag() { printf 'runner-v0.12.0\n'; }
github_api() { printf 'unexpected GitHub request\n' >&2; exit 9; }
OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
RELEASE_BASE_URL=https://emisar.dev/releases/runner
resolve_latest_version

REPO=example/emisar
github_api() { printf '%s' "$RELEASES"; }
resolve_latest_version
`, map[string]string{"RELEASES": releases})

	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if got := strings.TrimSpace(string(output)); got != "runner-v0.12.0\nrunner-v0.10.0" {
		return fmt.Errorf("resolved latest = %q, want mirror then GitHub fallback", got)
	}
	invalid := h.functions(h.repoPath("install.sh"), []string{"resolve_latest_version"}, `
die() { printf '%s\n' "$1" >&2; exit 1; }
warn() { :; }
release_manifest_tag() { return 2; }
resolve_latest_from_github() { printf 'GitHub fallback must not run\n' >&2; exit 9; }
OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
RELEASE_BASE_URL=https://emisar.dev/releases/runner
resolve_latest_version
`, nil)
	if err := expectFailure(invalid, "invalid runner latest.json"); err != nil {
		return fmt.Errorf("invalid mirror manifest did not fail closed: %w", err)
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
ETC_DIR=/etc/emisar
INSTALL_STATE_BACKUP=

printf 'fresh:\n' >>"$TRACE"
SERVICE_UNIT_CREATED=1
rollback_service
INIT=launchd
rollback_service

printf 'upgrade:\n' >>"$TRACE"
INIT=systemd
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
	for _, want := range []string{
		"systemctl disable --now emisar.service",
		"rm -f /etc/systemd/system/emisar.service",
		"rm -f /Library/LaunchDaemons/com.emisar.runner.plist",
		"rm -f /etc/emisar/run-launchd.sh",
	} {
		if !strings.Contains(fresh, want) {
			return fmt.Errorf("a failed fresh install did not run %q:\n%s", want, fresh)
		}
	}
	if strings.TrimSpace(upgrade) != "" {
		return fmt.Errorf("a failed UPGRADE removed the pre-existing unit:\n%s", upgrade)
	}
	return nil
}

// runnerIDOverride proves EMISAR_RUNNER_ID lands as runner.id in the generated
// config — the runner's declared name and identity — and that an unset
// variable emits no id line at all.
func runnerIDOverride(h *harness) error {
	script := "config_skeleton\n"
	base := map[string]string{
		"OS": "linux", "INIT": "systemd",
		"ETC_DIR": "/etc/emisar", "DATA_DIR": "/var/lib/emisar", "LOG_DIR": "/var/log/emisar",
		"EMISAR_URL": "", "EMISAR_ENROLLMENT_KEY": "",
	}

	withOverride := map[string]string{"EMISAR_RUNNER_ID": "web-01"}
	for k, v := range base {
		withOverride[k] = v
	}
	result := h.functions(h.repoPath("install.sh"), []string{"config_skeleton", "safe_config_value"},
		script, withOverride)
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if !strings.Contains(string(output), "id: web-01") {
		return fmt.Errorf("EMISAR_RUNNER_ID did not land in the config skeleton:\n%s", output)
	}

	result = h.functions(h.repoPath("install.sh"), []string{"config_skeleton", "safe_config_value"},
		script, base)
	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if strings.Contains(string(output), "\n  id:") {
		return fmt.Errorf("unset EMISAR_RUNNER_ID still emitted an id line:\n%s", output)
	}
	return nil
}

// runnerConfigValueValidation proves nothing that could break out of config.yaml
// gets baked into it.
//
// Labels, the runner group and the cloud URL all land inside YAML scalars. A
// quote does not corrupt the file, it ADDS to it — and a newline injects whole
// config KEYS: cloud.url, paths.packs, admission. Cloud-init rendering an
// instance tag into EMISAR_RUNNER_LABEL_* is the realistic source, so this is not a
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

// The download checksum is the ONLY integrity control on a host without `gh`:
// verify_attestation degrades to a warning there, so a tampered tarball is
// stopped by this comparison or not at all. Nothing exercised the mismatch,
// which meant a regression that let a bad tarball through — a dropped `|| die`,
// a grep that stopped matching — would have left every gate green. Drive the
// real download_release, with only the network and the attestation stubbed.
func runnerDownloadChecksum(h *harness) error {
	// A digest of the right shape that cannot be the tarball's.
	const wrongDigest = "0000000000000000000000000000000000000000000000000000000000000000"
	preamble := `
REPO=example/fork
OFFICIAL_REPO=emisar/official
OS=linux
ARCH=amd64
TARBALL=emisar-9.9.9-linux-amd64.tar.gz
log() { :; }
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
github_release_base() { printf 'https://example.invalid/%s\n' "$1"; }
verify_attestation() { printf 'ATTESTATION REACHED\n' >&2; }
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
build_tarball() {
  dir="$1"
  mkdir -p "${dir}/emisar-9.9.9-linux-amd64"
  printf 'binary\n' >"${dir}/emisar-9.9.9-linux-amd64/emisar"
  tar -C "${dir}" -czf "${dir}/${TARBALL}" emisar-9.9.9-linux-amd64
  rm -rf "${dir}/emisar-9.9.9-linux-amd64"
}
`
	tampered := h.functions(h.repoPath("install.sh"), []string{"download_release", "sha_verify"}, preamble+`
fetch_release_files() {
  dir="$3"
  build_tarball "$dir"
  printf '%s  %s\n' "`+wrongDigest+`" "$TARBALL" >"${dir}/SHA256SUMS"
}
tmp="$(mktemp -d)"
download_release runner-v9.9.9 "$tmp"
`, nil)
	if err := expectFailure(tampered, "checksum verification failed"); err != nil {
		return fmt.Errorf("a tampered tarball was not refused: %w", err)
	}
	// Refused BEFORE the provenance check and before anything is unpacked —
	// otherwise "fails closed" would only mean "fails eventually".
	if strings.Contains(string(tampered.output), "ATTESTATION REACHED") {
		return fmt.Errorf("install continued past the checksum mismatch:\n%s", tampered.output)
	}

	missing := h.functions(h.repoPath("install.sh"), []string{"download_release", "sha_verify"}, preamble+`
fetch_release_files() {
  dir="$3"
  build_tarball "$dir"
  printf '%s  %s\n' "`+wrongDigest+`" "emisar-9.9.9-linux-arm64.tar.gz" >"${dir}/SHA256SUMS"
}
tmp="$(mktemp -d)"
download_release runner-v9.9.9 "$tmp"
`, nil)
	if err := expectFailure(missing, "checksum manifest does not list emisar-9.9.9-linux-amd64.tar.gz"); err != nil {
		return fmt.Errorf("a manifest missing the selected tarball was not refused: %w", err)
	}
	if strings.Contains(string(missing.output), "ATTESTATION REACHED") {
		return fmt.Errorf("install continued past the missing checksum entry:\n%s", missing.output)
	}

	// The control: the identical path with an honest SHA256SUMS must succeed,
	// so the refusal above cannot be passing for some unrelated reason.
	honest := h.functions(h.repoPath("install.sh"), []string{"download_release", "sha_verify"}, preamble+`
fetch_release_files() {
  dir="$3"
  build_tarball "$dir"
  printf '%s  %s\n' "$(digest_of "${dir}/${TARBALL}")" "$TARBALL" >"${dir}/SHA256SUMS"
}
tmp="$(mktemp -d)"
download_release runner-v9.9.9 "$tmp"
`, nil)
	output, err := requireOutput(honest)
	if err != nil {
		return fmt.Errorf("a matching checksum did not install: %w", err)
	}
	if !strings.Contains(string(output), "ATTESTATION REACHED") {
		return fmt.Errorf("the verified path never reached attestation:\n%s", output)
	}
	return nil
}
