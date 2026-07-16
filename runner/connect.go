package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

func connectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "connect",
		Short: "Connect to the control plane and serve commands until stopped",
		Long: `connect runs the runner in daemon mode. It dials the configured
control-plane websocket, advertises this runner's actions, and processes
incoming RunAction messages. There is no inbound listener on this host.

On first connect, the runner presents the bootstrap auth key (env var
named by cloud.auth_key_env) to POST /runner/register, persists the
returned per-runner token to cloud.token_path, then upgrades to the
websocket. Subsequent boots reuse the cached token, so the auth key
env var can be unset after the first successful connect.`,
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

			authKey := os.Getenv(rt.cfg.Cloud.AuthKeyEnv)
			tokenPath := rt.cfg.Cloud.TokenPath
			if tokenPath == "" {
				tokenPath = filepath.Join(rt.cfg.Paths.DataDir, "token.json")
			}

			// AuthKey is only required on first connect (when no token
			// file exists yet). Subsequent boots reuse the persisted
			// per-runner token so the operator can unset the env var.
			if authKey == "" {
				if _, statErr := os.Stat(tokenPath); statErr != nil {
					return fmt.Errorf("first connect needs $%s; no cached token at %s",
						rt.cfg.Cloud.AuthKeyEnv, tokenPath)
				}
			}

			// Client-attested dispatch: build the verifier from config. When
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

			// Resolve identity only after acquiring the data-directory lock, so
			// two first boots cannot mint different ids for one installation.
			externalID, err := rt.ensureExternalID()
			if err != nil {
				return fmt.Errorf("resolve runner id: %w", err)
			}
			verifier, err := buildVerifier(rt.cfg, externalID, nonceStore)
			if err != nil {
				return fmt.Errorf("signing: %w", err)
			}

			hostname, _ := os.Hostname()
			logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
			// A degraded pack is skipped, not fatal (see loadRegistry) — but it
			// must be impossible to miss from the host: one line per pack, every
			// boot, naming the file to fix.
			for _, degraded := range rt.registry().Degraded() {
				logger.Error("packs.degraded",
					"pack_dir", degraded.Dir, "error", degraded.Reason)
			}
			dialer := &cloud.WebsocketDialer{
				URL:        rt.cfg.Cloud.URL,
				AuthKey:    authKey,
				TokenPath:  tokenPath,
				Hostname:   hostname,
				Group:      rt.cfg.Runner.Group,
				Version:    Version,
				ExternalID: externalID,
				Logger:     logger,
			}

			builder := &cloud.StateBuilder{
				Version:     Version,
				Hostname:    hostname,
				Group:       rt.cfg.Runner.Group,
				Labels:      rt.cfg.Runner.Labels,
				GetRegistry: rt.engine.Registry,
				Admission:   rt.admission,
			}
			client := cloud.NewClient(dialer, cloud.Options{
				StateBuilder:         builder,
				Engine:               rt.engine,
				DedupStorePath:       cloud.DispatchLogPath(rt.cfg.Paths.DataDir),
				DedupLegacyStorePath: cloud.LegacyDispatchLogPath(rt.cfg.Paths.DataDir),
				TerminalShutdownPath: cloud.TerminalShutdownStatePath(rt.cfg.Paths.DataDir),
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

			ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer cancel()

			// SIGHUP: reload packs and rebuild the signature verifier from the
			// (possibly edited) config, then re-send runner_state on the active
			// connection. Safe mid-action: the engine holds the registry and the
			// client holds the verifier behind atomic pointers, so in-flight runs
			// keep the pointers they captured at start. Every verifier shares the
			// process-lifetime nonce store, so replay state is continuous across
			// the construction-to-swap window.
			hup := make(chan os.Signal, 1)
			signal.Notify(hup, syscall.SIGHUP)
			defer signal.Stop(hup)
			go func() {
				for {
					select {
					case <-ctx.Done():
						return
					case <-hup:
						changed, packErr, signingErr := reloadComponents(
							rt.engine.Reload,
							func() error {
								verifier, err := reloadVerifier(externalID, nonceStore)
								if err == nil {
									client.SetVerifier(verifier)
								}
								return err
							},
						)
						if packErr != nil {
							logger.Error("reload_failed", "error", packErr)
						}
						if signingErr != nil {
							logger.Error("signing_reload_failed", "error", signingErr)
						}
						if changed {
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
		return fmt.Errorf("connect requires paths.data_dir for durable identity and dispatch reservations")
	}
	return nil
}

func lockConnectDataDir(dataDir string) (*fsutil.FileLock, error) {
	if err := fsutil.SecureMkdirAll(dataDir, 0o750); err != nil {
		return nil, fmt.Errorf("create runner data directory: %w", err)
	}
	lock, err := fsutil.AcquireFileLock(filepath.Join(dataDir, "runner.lock"))
	if err != nil {
		return nil, fmt.Errorf("lock runner data directory %q: %w", dataDir, err)
	}
	return lock, nil
}

func reloadComponents(reloadPacks, reloadSigning func() error) (changed bool, packErr, signingErr error) {
	packErr = reloadPacks()
	signingErr = reloadSigning()
	return packErr == nil || signingErr == nil, packErr, signingErr
}

// buildVerifier constructs the dispatch signature verifier from config: the
// trusted CAs, whether enforcement is on, the attestation freshness window, and
// the runner's local group/labels (the cert-scope identity). Every build receives
// the same process-owned nonce store; only immutable policy is replaced.
func buildVerifier(cfg *config.Config, externalID string, nonceStore *signing.NonceStore) (*signing.Verifier, error) {
	if cfg.Signing.EnforceSignatures && !nonceStore.Durable() {
		return nil, fmt.Errorf("signing: enforcement requires durable replay state")
	}
	return newVerifier(cfg, externalID, nonceStore)
}

func buildStateVerifier(cfg *config.Config, externalID string) (*signing.Verifier, error) {
	return newVerifier(cfg, externalID, signing.NewMemoryNonceStore())
}

func newVerifier(cfg *config.Config, externalID string, nonceStore *signing.NonceStore) (*signing.Verifier, error) {
	portalOrigin := ""
	if cfg.Signing.EnforceSignatures {
		var err error
		portalOrigin, err = canonicalPortalOrigin(cfg.Cloud.URL)
		if err != nil {
			return nil, fmt.Errorf("signing: portal origin: %w", err)
		}
	}
	cas := make([]signing.CAConfig, len(cfg.Signing.TrustedCAs))
	for i, ca := range cfg.Signing.TrustedCAs {
		cas[i] = signing.CAConfig{CAID: ca.CAID, PublicKeyHex: ca.PublicKey}
	}
	return signing.NewVerifier(
		cfg.Signing.EnforceSignatures, cas, cfg.Signing.MaxAttestationAge.Std(),
		externalID, portalOrigin, cfg.Runner.Group, cfg.Runner.Labels, nonceStore)
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

// reloadVerifier re-reads the config file and rebuilds the verifier so a SIGHUP
// picks up a rotated or revoked trusted key without a runner restart.
func reloadVerifier(externalID string, nonceStore *signing.NonceStore) (*signing.Verifier, error) {
	cfgPath, err := resolveConfigPath()
	if err != nil {
		return nil, fmt.Errorf("config path: %w", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}
	return buildVerifier(cfg, externalID, nonceStore)
}

// resolveExternalID returns the runner's durable identity. Precedence:
//  1. an operator-pinned `runner.id` in config, if set;
//  2. a UUID persisted at <data_dir>/runner_id from a previous boot;
//  3. a freshly minted UUID, persisted for next time.
//
// Presenting a stable id on every register lets the cloud map reconnects
// (and reboots) back to the same runner row instead of creating a new one.
func resolveExternalID(configuredID, dataDir string) (string, error) {
	id, found, err := existingExternalID(configuredID, dataDir)
	if err != nil || found {
		return id, err
	}

	id, err = newUUIDv4()
	if err != nil {
		return "", err
	}

	path := filepath.Join(dataDir, "runner_id")
	if err := fsutil.SecureMkdirAll(filepath.Dir(path), 0o750); err != nil {
		return "", err
	}
	// Sync the file and its directory around the atomic rename. Returning an id
	// before the directory entry is durable can mint a different logical runner
	// after a power loss, which defeats dispatch and nonce isolation.
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", fmt.Errorf("create runner identity: %w", err)
	}
	cleanup := func() {
		_ = f.Close()
		_ = os.Remove(tmp)
	}
	if err := f.Chmod(0o600); err != nil {
		cleanup()
		return "", fmt.Errorf("secure runner identity: %w", err)
	}
	if _, err := f.WriteString(id); err != nil {
		cleanup()
		return "", fmt.Errorf("write runner identity: %w", err)
	}
	if err := f.Sync(); err != nil {
		cleanup()
		return "", fmt.Errorf("sync runner identity: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("close runner identity: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("activate runner identity: %w", err)
	}
	if err := fsutil.SyncDirectory(filepath.Dir(path)); err != nil {
		return "", fmt.Errorf("sync runner identity directory: %w", err)
	}
	return id, nil
}

func existingExternalID(configuredID, dataDir string) (string, bool, error) {
	if id := strings.TrimSpace(configuredID); id != "" {
		return id, true, nil
	}

	path := filepath.Join(dataDir, "runner_id")
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("read runner identity %s: %w", path, err)
	}
	id := strings.TrimSpace(string(b))
	if id == "" {
		return "", false, fmt.Errorf("runner identity %s is empty", path)
	}
	return id, true, nil
}

// newUUIDv4 builds an RFC 4122 v4 UUID from crypto/rand — no external dep.
func newUUIDv4() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
