package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
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

			logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
			dialer := &cloud.WebsocketDialer{
				URL:       rt.cfg.Cloud.URL,
				AuthKey:   authKey,
				TokenPath: tokenPath,
				Hostname:  hostname,
				Group:     rt.cfg.Runner.Group,
				Version:   Version,
				Logger:    logger,
			}

			builder := &cloud.StateBuilder{
				AgentID:     rt.cfg.Runner.ID,
				Version:     Version,
				Group:       rt.cfg.Runner.Group,
				Labels:      rt.cfg.Runner.Labels,
				GetRegistry: rt.engine.Registry,
			}
			client := cloud.NewClient(dialer, cloud.Options{
				StateBuilder:   builder,
				Engine:         rt.engine,
				Cursor:         rt.cursor,
				Logger:         logger,
				HeartbeatEvery: rt.cfg.Cloud.HeartbeatEvery.Std(),
				ReconnectMin:   rt.cfg.Cloud.ReconnectMin.Std(),
				ReconnectMax:   rt.cfg.Cloud.ReconnectMax.Std(),
			})

			ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer cancel()

			// SIGHUP: reload packs, then ask the client to re-send
			// agent_state on the active connection. Reloading mid-action
			// is safe because the engine holds the registry behind an
			// atomic pointer and in-flight runs captured their pointer
			// at start.
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
