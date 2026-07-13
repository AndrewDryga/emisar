package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
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
			rt, err := boot()
			if err != nil {
				return err
			}
			defer rt.journal.Close()

			if rt.cfg.Cloud.URL == "" {
				return fmt.Errorf("cloud.url not set in config (this binary has no other long-running mode)")
			}

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

			hostname, _ := os.Hostname()

			// Durable identity, persisted next to the token so reconnects
			// (and reboots) map back to the same runner row in the cloud.
			externalID, err := resolveExternalID(rt.cfg.Runner.ID, rt.cfg.Paths.DataDir)
			if err != nil {
				return fmt.Errorf("resolve runner id: %w", err)
			}

			// Client-attested dispatch: build the verifier from config. When
			// enforcing, the runner advertises it (cloud disables its own
			// dispatch) and verifies a signature on every run. SIGHUP rebuilds
			// it so a rotated/revoked key takes effect without a restart.
			nonceStore, err := openNonceStore(rt.cfg)
			if err != nil {
				return fmt.Errorf("signing: %w", err)
			}
			// connect owns this store for the process lifetime and shares it with
			// every verifier. It needs no Close: persistence opens, atomically
			// replaces, and closes the state file within each nonce consumption.
			verifier, err := buildVerifier(rt.cfg, externalID, nonceStore)
			if err != nil {
				return fmt.Errorf("signing: %w", err)
			}

			logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
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
				// The RESOLVED durable id (config → persisted → fresh UUID), the
				// same one we register with above — not the config-only
				// rt.cfg.Runner.ID, which is empty when the operator didn't pin
				// one, making the runner advertise runner_id: "".
				AgentID:     externalID,
				Version:     Version,
				Hostname:    hostname,
				Group:       rt.cfg.Runner.Group,
				Labels:      rt.cfg.Runner.Labels,
				GetRegistry: rt.engine.Registry,
				Admission:   rt.admission,
			}
			dedupStorePath := ""
			if rt.cfg.Paths.DataDir != "" {
				dedupStorePath = filepath.Join(rt.cfg.Paths.DataDir, "dedup.jsonl")
			}
			client := cloud.NewClient(dialer, cloud.Options{
				StateBuilder:   builder,
				Engine:         rt.engine,
				Cursor:         rt.cursor,
				DedupStorePath: dedupStorePath,
				Logger:         logger,
				HeartbeatEvery: rt.cfg.Cloud.HeartbeatEvery.Std(),
				ReconnectMin:   rt.cfg.Cloud.ReconnectMin.Std(),
				ReconnectMax:   rt.cfg.Cloud.ReconnectMax.Std(),
				Verifier:       verifier,
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
						if err := rt.engine.Reload(); err != nil {
							logger.Error("reload_failed", "error", err)
							continue
						}
						// Pack reload succeeded; refresh signing keys independently
						// so a key-only edit (rotation/revocation) takes effect, and
						// still re-advertise the packs even if the signing reload fails.
						if verifier, err := reloadVerifier(externalID, nonceStore); err != nil {
							logger.Error("signing_reload_failed", "error", err)
						} else {
							client.SetVerifier(verifier)
						}
						client.Readvertise()
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

// buildVerifier constructs the dispatch signature verifier from config: the
// trusted CAs, whether enforcement is on, the attestation freshness window, and
// the runner's local group/labels (the cert-scope identity). Every build receives
// the same process-owned nonce store; only immutable policy is replaced.
func buildVerifier(cfg *config.Config, externalID string, nonceStore *signing.NonceStore) (*signing.Verifier, error) {
	cas := make([]signing.CAConfig, len(cfg.Signing.TrustedCAs))
	for i, ca := range cfg.Signing.TrustedCAs {
		cas[i] = signing.CAConfig{CAID: ca.CAID, PublicKeyHex: ca.PublicKey}
	}
	return signing.NewVerifier(
		cfg.Signing.EnforceSignatures, cas, cfg.Signing.MaxAttestationAge.Std(),
		externalID, cfg.Runner.Group, cfg.Runner.Labels, nonceStore)
}

func openNonceStore(cfg *config.Config) (*signing.NonceStore, error) {
	storePath := ""
	if cfg.Paths.DataDir != "" {
		storePath = filepath.Join(cfg.Paths.DataDir, "signing", "nonce-cache.json")
	}
	return signing.OpenNonceStore(storePath, cfg.Signing.MaxAttestationAge.Std())
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
	if id := strings.TrimSpace(configuredID); id != "" {
		return id, nil
	}

	path := filepath.Join(dataDir, "runner_id")
	if b, err := os.ReadFile(path); err == nil {
		if id := strings.TrimSpace(string(b)); id != "" {
			return id, nil
		}
	}

	id, err := newUUIDv4()
	if err != nil {
		return "", err
	}

	if err := fsutil.SecureMkdirAll(filepath.Dir(path), 0o750); err != nil {
		return "", err
	}
	// Write atomically so a crash mid-write can't leave a corrupt id.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(id), 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", err
	}
	return id, nil
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
