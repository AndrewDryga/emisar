package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
	"github.com/andrewdryga/emisar/runner/internal/redact"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

func connectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "connect",
		Short: "Connect to the control plane and serve commands until stopped",
		Long: `connect runs the runner in daemon mode. It dials the configured
control-plane websocket, advertises this runner's actions, and processes
incoming RunAction messages. There is no inbound listener on this host.

On first connect, the runner presents the bootstrap enrollment key (env var
named by cloud.enrollment_key_env) to POST /runner/register, persists the
returned per-runner token to cloud.token_path, then upgrades to the
websocket. Subsequent boots reuse the cached token, so the enrollment key
env var can be unset after the first successful connect.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			if cfg.Cloud.URL == "" {
				return fmt.Errorf("cloud.url not set in config (this binary has no other long-running mode)")
			}
			if err := validateConnectDataDir(cfg.Paths.DataDir); err != nil {
				return err
			}
			dataDirLock, err := lockConnectDataDir(cfg.Paths.DataDir)
			if err != nil {
				return err
			}
			defer dataDirLock.Close()

			rt, err := bootWithConfig(cfg)
			if err != nil {
				return err
			}
			defer rt.journal.Close()

			enrollmentKey := os.Getenv(rt.cfg.Cloud.EnrollmentKeyEnv)
			tokenPath := rt.cfg.Cloud.TokenPath
			if tokenPath == "" {
				tokenPath = filepath.Join(rt.cfg.Paths.DataDir, "token.json")
			}

			// EnrollmentKey is only required on first connect (when no token
			// file exists yet). Subsequent boots reuse the persisted
			// per-runner token so the operator can unset the env var.
			if enrollmentKey == "" {
				if _, statErr := os.Stat(tokenPath); statErr != nil {
					return fmt.Errorf("first connect needs $%s; no cached token at %s",
						rt.cfg.Cloud.EnrollmentKeyEnv, tokenPath)
				}
			}

			// Bridge-attested dispatch: build the verifier from config. When
			// enforcing, the runner advertises it (cloud disables its own
			// dispatch) and verifies a signature on every run. SIGHUP rebuilds
			// it so a rotated/revoked key takes effect without a restart.
			nonceStore, err := openRuntimeNonceStore(rt.cfg)
			if err != nil {
				return fmt.Errorf("signing: %w", err)
			}
			// connect owns this store for the process lifetime and shares it with
			// every verifier replacement.
			defer nonceStore.Close()

			verifier, err := buildVerifier(rt.cfg, rt.identity(), nonceStore)
			if err != nil {
				return fmt.Errorf("signing: %w", err)
			}

			logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
			// A degraded pack is skipped, not fatal (see loadRegistry) — but it
			// must be impossible to miss from the host: one line per pack, every
			// boot, naming the file to fix.
			for _, degraded := range rt.registry().Degraded() {
				logger.Error("packs.degraded",
					"pack_dir", degraded.Dir, "error", degraded.Reason)
			}
			dialer := &cloud.WebsocketDialer{
				URL:           rt.cfg.Cloud.URL,
				EnrollmentKey: enrollmentKey,
				TokenPath:     tokenPath,
				Hostname:      rt.hostname,
				Group:         rt.cfg.Runner.Group,
				Version:       Version,
				ExternalID:    rt.externalID,
				Logger:        logger,
			}

			builder := &cloud.StateBuilder{
				Version:  Version,
				Hostname: rt.hostname,
				// Identity is fixed for the process: the control plane knows
				// this runner by what it registered as, and the journal stamps
				// every event with it. A changed runner.group/labels is
				// reported as restart-required by reloadRuntime rather than
				// half-applied.
				Group:        rt.cfg.Runner.Group,
				Labels:       rt.cfg.Runner.Labels,
				GetRegistry:  rt.engine.Registry,
				GetAdmission: rt.engine.Admission,
			}
			client := cloud.NewClient(dialer, cloud.Options{
				StateBuilder:         builder,
				Engine:               rt.engine,
				DedupStorePath:       cloud.DispatchLogPath(rt.cfg.Paths.DataDir),
				DedupLegacyStorePath: cloud.LegacyDispatchLogPath(rt.cfg.Paths.DataDir),
				TerminalShutdownPath: cloud.TerminalShutdownStatePath(rt.cfg.Paths.DataDir),
				RuntimeStatusPath:    cloud.RuntimeStatusPath(rt.cfg.Paths.DataDir),
				Logger:               logger,
				HeartbeatEvery:       rt.cfg.Cloud.HeartbeatEvery.Std(),
				ReconnectMin:         rt.cfg.Cloud.ReconnectMin.Std(),
				ReconnectMax:         rt.cfg.Cloud.ReconnectMax.Std(),
				Verifier:             verifier,
			})
			// Advertise the trusted key set live: the builder reads the client's
			// verifier (like it reads the engine registry), so a SIGHUP key swap
			// re-advertises on the next Readvertise — one source of truth.
			builder.GetVerifier = client.Verifier

			// Interrupt/termination cancellation comes from main's process-wide
			// signal context via cmd.Context(); SIGHUP stays connect-local below.
			ctx := cmd.Context()

			// SIGHUP: re-read the config and apply every section a live runner
			// can change, then re-send runner_state on the active connection.
			// Safe mid-action: packs, admission, redaction and the verifier all
			// sit behind atomic pointers, so in-flight runs keep what they
			// captured at start. Every verifier shares the process-lifetime
			// nonce store, so replay state is continuous across the
			// construction-to-swap window.
			hup := make(chan os.Signal, 1)
			signal.Notify(hup, syscall.SIGHUP)
			defer signal.Stop(hup)
			go func() {
				for {
					select {
					case <-ctx.Done():
						return
					case <-hup:
						if reloadRuntime(rt, client, nonceStore, logger) {
							client.Readvertise()
						}
					}
				}
			}()

			banner("emisar connecting to %s (group=%s packs=%d actions=%d)",
				rt.cfg.Cloud.URL,
				rt.cfg.Runner.Group,
				len(rt.registry().Packs()),
				len(rt.registry().Actions()),
			)

			err = client.Run(ctx)
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil
			}
			return err
		},
	}
}

func validateConnectDataDir(dataDir string) error {
	if strings.TrimSpace(dataDir) == "" {
		return fmt.Errorf("connect requires paths.data_dir for durable dispatch reservations")
	}
	return nil
}

func lockConnectDataDir(dataDir string) (*fsutil.FileLock, error) {
	if err := fsutil.SecureMkdirAll(dataDir, 0o750); err != nil {
		return nil, fmt.Errorf("create runner data directory: %w", err)
	}
	lock, err := fsutil.AcquireFileLock(runnerLockPath(dataDir))
	if err != nil {
		return nil, fmt.Errorf("lock runner data directory %q: %w", dataDir, err)
	}
	// Record our PID in the held lock so `emisar pack install/update/uninstall`
	// can SIGHUP the daemon into a reload (see notifyRunnerReload). Best-effort:
	// the lock is load-bearing, the record is a convenience.
	if err := lock.WriteRecord([]byte(strconv.Itoa(os.Getpid()))); err != nil {
		slog.Warn("could not record pid in runner.lock", "error", err)
	}
	return lock, nil
}

// runnerLockPath is the single-instance daemon lock inside the data dir —
// shared with the CLI-side reload probe, which reads the recorded PID.
func runnerLockPath(dataDir string) string {
	return filepath.Join(dataDir, "runner.lock")
}

// reloadRuntime re-reads the config file and applies every section a running
// runner can change: the installed packs, the local admission policy, the
// global redaction rules, and the signature verifier. It reports whether
// anything was applied so the caller only re-advertises when it was.
//
// Everything else is bound to a resource this process holds for its lifetime —
// the identity it registered under and stamps on every journal event, the
// control-plane connection, the locked data directory, the open journal — and
// a live swap of those is a different runner, not a reload. Each such section
// that DIFFERS is named at Warn with "restart required". Silence was the bug:
// an operator who tightened admission.deny and reloaded was told the reload
// succeeded while the runner kept admitting the actions they had just banned.
func reloadRuntime(
	rt *runtime, client *cloud.Client, nonceStore *signing.NonceStore, logger *slog.Logger,
) (applied bool) {
	// Packs first, and independently of the config file: `pack install` sends
	// the SIGHUP that picks the new pack up, and it reloads from the same dirs
	// this process booted with, so an unreadable config must not block it.
	if err := rt.engine.Reload(); err != nil {
		logger.Error("reload_failed", "error", err)
	} else {
		applied = true
	}

	cfg, err := loadConfig()
	if err != nil {
		logger.Error("reload_failed", "error", err)
		return applied
	}
	for _, section := range restartRequiredChanges(rt.cfg, cfg) {
		logger.Warn("reload_restart_required",
			"section", section,
			"detail", "this section changed on disk; only a restart applies it")
	}

	if admit, err := admission.New(
		cfg.Admission.Allow, cfg.Admission.Deny, cfg.Admission.MaxRisk,
	); err != nil {
		logger.Error("admission_reload_failed", "error", err)
	} else {
		rt.engine.SetAdmission(admit)
		applied = true
	}

	if rules, err := redact.CompileAll(redact.DefaultRules(), cfg.Redaction.Rules); err != nil {
		logger.Error("redaction_reload_failed", "error", err)
	} else {
		rt.engine.SetRedactor(redact.New(rules))
		applied = true
	}

	// The verifier follows the reloaded signing policy but keeps the BOOT
	// identity: certificate scope is judged against the same group and labels
	// this runner advertises, so the enforced and the advertised identity
	// cannot drift apart.
	if verifier, err := buildVerifier(cfg, rt.identity(), nonceStore); err != nil {
		logger.Error("signing_reload_failed", "error", err)
	} else {
		client.SetVerifier(verifier)
		applied = true
	}
	return applied
}

// restartRequiredChanges names the config sections that differ from the ones
// this process booted with and cannot be applied to it.
func restartRequiredChanges(booted, current *config.Config) []string {
	var sections []string
	if !reflect.DeepEqual(booted.Runner, current.Runner) {
		sections = append(sections, "runner")
	}
	if !reflect.DeepEqual(booted.Cloud, current.Cloud) {
		sections = append(sections, "cloud")
	}
	if !reflect.DeepEqual(booted.Paths, current.Paths) {
		sections = append(sections, "paths")
	}
	if !reflect.DeepEqual(booted.Execution, current.Execution) {
		sections = append(sections, "execution")
	}
	if !reflect.DeepEqual(booted.Events, current.Events) {
		sections = append(sections, "events")
	}
	return sections
}

// buildVerifier constructs the dispatch signature verifier from config: the
// trusted CAs, whether enforcement is on, the attestation freshness window, and
// the runner's boot identity (the portal-origin and cert-scope ceilings). Every
// build receives the same process-owned nonce store and the same identity; only
// signing policy is replaced.
func buildVerifier(
	cfg *config.Config, id runnerIdentity, nonceStore *signing.NonceStore,
) (*signing.Verifier, error) {
	if cfg.Signing.EnforceSignatures && !nonceStore.Durable() {
		return nil, fmt.Errorf("signing: enforcement requires durable replay state")
	}
	return newVerifier(cfg, id, nonceStore)
}

func buildStateVerifier(cfg *config.Config, id runnerIdentity) (*signing.Verifier, error) {
	return newVerifier(cfg, id, signing.NewMemoryNonceStore())
}

func newVerifier(
	cfg *config.Config, id runnerIdentity, nonceStore *signing.NonceStore,
) (*signing.Verifier, error) {
	portalOrigin := ""
	if cfg.Signing.EnforceSignatures {
		var err error
		portalOrigin, err = canonicalPortalOrigin(id.portalURL)
		if err != nil {
			return nil, fmt.Errorf("signing: portal origin: %w", err)
		}
	}
	cas := make([]signing.CAConfig, len(cfg.Signing.TrustedCAs))
	for i, ca := range cfg.Signing.TrustedCAs {
		cas[i] = signing.CAConfig{Name: ca.Name, PEM: ca.PEM}
	}
	return signing.NewVerifier(
		cfg.Signing.EnforceSignatures, cas, cfg.Signing.MaxAttestationAge.Std(),
		id.externalID, portalOrigin, id.group, id.labels, nonceStore)
}

// canonicalPortalOrigin maps the runner's websocket/HTTP control-plane URL to
// the HTTP origin the MCP bridge signs. Paths never participate in the origin;
// default ports and DNS casing are normalized identically to the bridge.
func canonicalPortalOrigin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("parse %q: %w", raw, err)
	}
	if !u.IsAbs() || u.Opaque != "" || u.Hostname() == "" || u.User != nil {
		return "", fmt.Errorf("%q must be an absolute control-plane URL without credentials", raw)
	}
	scheme := strings.ToLower(u.Scheme)
	switch scheme {
	case "https", "wss":
		scheme = "https"
	case "http", "ws":
		scheme = "http"
	default:
		return "", fmt.Errorf("%q has unsupported scheme %q", raw, u.Scheme)
	}
	host := strings.ToLower(u.Host)
	if (scheme == "https" && u.Port() == "443") || (scheme == "http" && u.Port() == "80") {
		host = strings.TrimSuffix(host, ":"+u.Port())
	}
	return scheme + "://" + host, nil
}

func openNonceStore(cfg *config.Config) (*signing.NonceStore, error) {
	storePath := filepath.Join(cfg.Paths.DataDir, "signing", "nonce-cache.json")
	return signing.OpenNonceStore(storePath, cfg.Signing.MaxAttestationAge.Std())
}

func openRuntimeNonceStore(cfg *config.Config) (*signing.NonceStore, error) {
	if !cfg.Signing.EnforceSignatures {
		return signing.NewMemoryNonceStore(), nil
	}
	return openNonceStore(cfg)
}

// resolveExternalID uses the host lifecycle as the default identity boundary.
// A reboot keeps the hostname; replacing an ephemeral host produces a new one.
func resolveExternalID(configuredID, hostname string) (string, error) {
	if id := strings.TrimSpace(configuredID); id != "" {
		return id, nil
	}
	if hostname = strings.TrimSpace(hostname); hostname != "" {
		return hostname, nil
	}
	return "", fmt.Errorf("runner hostname is empty")
}
