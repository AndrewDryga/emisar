package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// registryPack is one entry of the registry's /packs.json index — the
// fields `pack update` needs to tell whether an installed pack is stale
// (hash) and to report the move (version).
type registryPack struct {
	ID      string `json:"id"`
	Version string `json:"version"`
	Hash    string `json:"hash"`
}

type installedPack struct {
	id      string
	version string
	hash    string
	root    string
	loadErr error
}

func packUpdateCmd() *cobra.Command {
	var (
		registry string
		dryRun   bool
	)
	cmd := &cobra.Command{
		Use:   "update [id...]",
		Short: "Update installed packs to the registry's current versions",
		Long: `Pull newer versions of the installed packs from the registry.

For each installed pack, its content hash is compared to the registry's
(from <registry>/packs.json). When they differ, the new pack is fetched,
validated, hash-verified against the index, and swapped into place — so a
pack updates only when the registry actually has different content, and a
half-downloaded pack never replaces a working one.

With no arguments every installed pack is checked; pass ids to update just
those. Packs not in the registry (locally authored) are left untouched.
--dry-run reports what would change without touching anything.

After updating, a running daemon is reloaded automatically (SIGHUP) so it
re-reads the catalog; without one: sudo systemctl reload emisar

  emisar pack update                  # check + update every installed pack
  emisar pack update redis postgres   # just these
  emisar pack update --dry-run`,
		RunE: func(cmd *cobra.Command, args []string) error {
			if registry == "" {
				registry = os.Getenv("EMISAR_PACKS_REGISTRY")
			}
			if registry == "" {
				registry = defaultRegistry
			}

			dirs, err := resolvePackDirs()
			if err != nil {
				return err
			}

			index, err := fetchPackIndex(cmd.Context(), registry)
			if err != nil {
				return err
			}

			only := map[string]bool{}
			for _, a := range args {
				only[a] = true
			}

			seen := map[string]bool{}
			var updated, current, skipped, failed int

			for _, dir := range dirs {
				installed, err := inspectInstalledPacks(dir)
				if err != nil {
					return err
				}
				for _, p := range installed {
					seen[p.id] = true
					if len(only) > 0 && !only[p.id] {
						continue
					}

					rp, inRegistry := index[p.id]
					if !inRegistry {
						if p.loadErr != nil {
							fmt.Printf("  %-22s invalid and not in registry — left as-is: %v\n", p.id, p.loadErr)
							failed++
						} else {
							fmt.Printf("  %-22s not in registry — left as-is\n", p.id)
							skipped++
						}
						continue
					}

					if p.loadErr == nil && hashEqual(p.hash, rp.Hash) {
						fmt.Printf("  %-22s up to date (v%s)\n", p.id, p.version)
						current++
						continue
					}

					if dryRun {
						if p.loadErr != nil {
							fmt.Printf("  %-22s invalid install → v%s (repair available)\n", p.id, rp.Version)
						} else {
							fmt.Printf("  %-22s v%s → v%s (update available)\n", p.id, p.version, rp.Version)
						}
						updated++
						continue
					}

					if err := updateOnePack(cmd.Context(), p.id, p.root, registry, rp); err != nil {
						fmt.Printf("  %-22s update FAILED: %v\n", p.id, err)
						failed++
						continue
					}
					if p.loadErr != nil {
						fmt.Printf("  %-22s invalid install → v%s repaired\n", p.id, rp.Version)
					} else {
						fmt.Printf("  %-22s v%s → v%s updated\n", p.id, p.version, rp.Version)
					}
					updated++
				}
			}

			// Requested ids that aren't installed anywhere — surface so a typo
			// doesn't look like a silent no-op.
			for id := range only {
				if !seen[id] {
					fmt.Printf("  %-22s not installed\n", id)
				}
			}

			if len(seen) == 0 {
				fmt.Printf("No packs installed in %s.\n", strings.Join(dirs, ", "))
				return nil
			}

			fmt.Println()
			if dryRun {
				fmt.Printf("%d to update, %d up to date, %d not in registry, %d failed.\n",
					updated, current, skipped, failed)
				if updated > 0 {
					fmt.Println("Run without --dry-run to apply.")
				}
				if failed > 0 {
					return fmt.Errorf("%d pack(s) failed to update", failed)
				}
				return nil
			}

			if failed > 0 {
				fmt.Printf("%d updated, %d up to date, %d not in registry, %d failed.\n",
					updated, current, skipped, failed)
				return fmt.Errorf("%d pack(s) failed to update", failed)
			}
			if _, err := packs.LoadAll(dirs, packs.LoadOptions{}); err != nil {
				return fmt.Errorf("validate installed packs after update: %w", err)
			}
			fmt.Printf("%d updated, %d up to date, %d not in registry, 0 failed.\n",
				updated, current, skipped)
			if updated > 0 {
				announceReload(os.Stdout, nil, "Reload the runner to load the new versions: sudo systemctl reload emisar")
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&registry, "registry", "", "pack registry base URL (default $EMISAR_PACKS_REGISTRY or "+defaultRegistry+")")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "report what would change without updating")
	return cmd
}

// inspectInstalledPacks deliberately loads each pack independently. A broken
// official pack must remain discoverable so `pack update` can replace it; the
// runtime's all-or-nothing loader still fails closed on the same bytes.
func inspectInstalledPacks(dir string) ([]installedPack, error) {
	roots, err := installedPackRoots(dir)
	if err != nil {
		return nil, err
	}
	result := make([]installedPack, 0, len(roots))
	for _, root := range roots {
		fallbackID := filepath.Base(root)
		reg, err := packs.LoadOne(root, packs.LoadOptions{})
		if err != nil {
			if !packspec.ValidPackID(fallbackID) {
				return nil, fmt.Errorf("inspect installed pack %s: invalid directory id and pack: %w", root, err)
			}
			result = append(result, installedPack{id: fallbackID, root: root, loadErr: err})
			continue
		}
		pack := reg.Packs()[0]
		hash, _ := reg.PackHash(pack.ID)
		result = append(result, installedPack{
			id: pack.ID, version: pack.Version, hash: hash, root: root,
		})
	}
	return result, nil
}

func installedPackRoots(dir string) ([]string, error) {
	info, err := os.Stat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect installed packs in %s: %w", dir, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("inspect installed packs: %s is not a directory", dir)
	}
	if _, err := os.Stat(filepath.Join(dir, "pack.yaml")); err == nil {
		return []string{dir}, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("inspect installed packs in %s: %w", dir, err)
	}
	roots := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		root := filepath.Join(dir, entry.Name())
		if _, err := os.Stat(filepath.Join(root, "pack.yaml")); err == nil {
			roots = append(roots, root)
		}
	}
	return roots, nil
}

// updateOnePack fetches id from the registry, verifies it validates and its
// hash matches the index, then replaces it through the rollback-safe shared
// pack installer. A failed stage or activation leaves the old tree available.
func updateOnePack(ctx context.Context, id, target, registry string, rp registryPack) error {
	url := strings.TrimRight(registry, "/") + "/packs/" + id + "/pack.tar.gz"
	src, cleanup, err := packs.Fetch(ctx, url, nil)
	if err != nil {
		return err
	}
	if cleanup != nil {
		defer cleanup()
	}

	reg, err := packs.LoadOne(src, packs.LoadOptions{})
	if err != nil {
		return err
	}
	fetched := reg.Packs()[0]
	if fetched.ID != id {
		return fmt.Errorf("registry served pack %q, expected %q", fetched.ID, id)
	}
	got, _ := reg.PackHash(fetched.ID)
	if !hashEqual(got, rp.Hash) {
		return fmt.Errorf("hash mismatch: index advertised %s, tarball is %s", normalizeHash(rp.Hash), got)
	}

	return replacePackTree(src, target, true)
}

// fetchPackIndex GETs the registry's /packs.json and returns it keyed by id.
func fetchPackIndex(ctx context.Context, registry string) (map[string]registryPack, error) {
	url := strings.TrimRight(registry, "/") + "/packs.json"
	if err := config.CheckEndpointScheme(url, false); err != nil {
		return nil, fmt.Errorf("fetch pack index: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := packRegistryHTTPClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch pack index %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch pack index %s: HTTP %d", url, resp.StatusCode)
	}

	var doc struct {
		Packs []registryPack `json:"packs"`
	}
	// 8 MiB bounds the full index (~58 packs is tens of KB) against a runaway body.
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&doc); err != nil {
		return nil, fmt.Errorf("parse pack index %s: %w", url, err)
	}

	out := make(map[string]registryPack, len(doc.Packs))
	for _, p := range doc.Packs {
		out[p.ID] = p
	}
	return out, nil
}

func packRegistryHTTPClient() *http.Client {
	client := httpsecurity.ClientWithTLS12(&http.Client{Timeout: 15 * time.Second})
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("stopped after 10 redirects")
		}
		if err := config.CheckEndpointScheme(req.URL.String(), false); err != nil {
			return fmt.Errorf("redirect refused: %w", err)
		}
		if len(via) > 0 && via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
			return fmt.Errorf("redirect refused HTTPS downgrade")
		}
		return nil
	}
	return client
}
