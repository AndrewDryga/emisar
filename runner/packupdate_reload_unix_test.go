//go:build !windows

package main

import (
	"encoding/json"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCLI_PackUpdateReloadsSuccessfulChanges(t *testing.T) {
	for _, tc := range []struct {
		name                                 string
		json, partial, dryRun, current, fail bool
	}{
		{name: "JSON success", json: true},
		{name: "human partial failure", partial: true},
		{name: "JSON partial failure", json: true, partial: true},
		{name: "dry run", json: true, dryRun: true},
		{name: "up to date", json: true, current: true},
		{name: "all failed", json: true, fail: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir, dest := t.TempDir(), t.TempDir()
			source := writeSourcePack(t, "redis")
			candidateHash := packHashOnDisk(t, source, "redis")
			old := staticPack(t, "0.0.0", "low")
			if tc.current {
				old = source
			}
			installed := filepath.Join(dest, "redis")
			if err := copyTree(old, installed); err != nil {
				t.Fatal(err)
			}
			oldHash := packHashOnDisk(t, installed, "redis")
			index := []registryPack{{ID: "redis", Version: "0.0.1", Hash: candidateHash}}
			tarballs := map[string][]byte{"redis": tarDir(t, source)}
			if tc.fail {
				index[0].Hash = "sha256:" + strings.Repeat("1", 64)
			}
			if tc.partial {
				installPackInto(t, dest, "postgres")
				index = append(index, registryPack{ID: "postgres", Version: "0.0.1", Hash: "sha256:" + strings.Repeat("1", 64)})
				tarballs["postgres"] = tarDir(t, writeSourcePack(t, "postgres"))
			}
			registry := fakeRegistry(t, index, tarballs)
			cfg := writeMinimalConfig(t, dir, dest)
			lock, err := lockConnectDataDir(filepath.Join(dir, "data"))
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = lock.Close() }()
			hup := make(chan os.Signal, 1)
			signal.Notify(hup, syscall.SIGHUP)
			defer signal.Stop(hup)

			args := []string{"--config", cfg, "pack", "update", "--registry", registry}
			if tc.json {
				args = append(args, "--json")
			}
			if tc.dryRun {
				args = append(args, "--dry-run")
			}
			stdout, stderr, code := runCLI(t, args, nil)
			wantCode := 0
			if tc.partial || tc.fail {
				wantCode = 1
			}
			if code != wantCode {
				t.Fatalf("exit = %d, want %d\nstdout=%s\nstderr=%s", code, wantCode, stdout, stderr)
			}
			if tc.json {
				var report packUpdateReport
				if err := json.Unmarshal([]byte(stdout), &report); err != nil {
					t.Fatalf("stdout must remain one JSON report: %v\n%s", err, stdout)
				}
				if report.Failed != wantCode {
					t.Fatalf("report = %+v, want %d failure(s)", report, wantCode)
				}
			}
			changed := !tc.dryRun && !tc.current && !tc.fail
			wantHash := oldHash
			if changed {
				wantHash = candidateHash
			}
			if got := packHashOnDisk(t, installed, "redis"); got != wantHash {
				t.Fatalf("installed hash = %s, want %s", got, wantHash)
			}
			if changed {
				notice := stdout
				if tc.json {
					notice = stderr
				}
				if !strings.Contains(notice, "Signaled the runner to reload") {
					t.Fatalf("missing reload notice in the diagnostic stream: %s", notice)
				}
				select {
				case <-hup:
				case <-time.After(2 * time.Second):
					t.Fatalf("successful replacement did not signal the daemon\nstdout=%s\nstderr=%s", stdout, stderr)
				}
			} else {
				select {
				case <-hup:
					t.Fatal("unchanged packs must not signal the daemon")
				case <-time.After(100 * time.Millisecond):
				}
			}
		})
	}
}
