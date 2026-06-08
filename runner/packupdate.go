package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// registryPack is one entry of the registry's /packs.json index — the
// fields `pack update` needs to tell whether an installed pack is stale
// (hash) and to report the move (version).
type registryPack struct {
	ID      string `json:"id"`
	Version string `json:"version"`
	Hash    string `json:"hash"`
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

After updating, reload the runner so it re-reads the catalog:
sudo systemctl reload emisar

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
				reg, err := packs.LoadAll([]string{dir}, packs.LoadOptions{})
				if err != nil {
					return fmt.Errorf("load installed packs from %s: %w", dir, err)
				}
				for _, p := range reg.Packs() {
					seen[p.ID] = true
					if len(only) > 0 && !only[p.ID] {
						continue
					}

					rp, inRegistry := index[p.ID]
					if !inRegistry {
						fmt.Printf("  %-22s not in registry — left as-is\n", p.ID)
						skipped++
						continue
					}

					installed, _ := reg.PackHash(p.ID)
					if hashEqual(installed, rp.Hash) {
						fmt.Printf("  %-22s up to date (v%s)\n", p.ID, p.Version)
						current++
						continue
					}

					if dryRun {
						fmt.Printf("  %-22s v%s → v%s (update available)\n", p.ID, p.Version, rp.Version)
						updated++
						continue
					}

					if err := updateOnePack(cmd.Context(), p.ID, dir, registry, rp); err != nil {
						fmt.Printf("  %-22s update FAILED: %v\n", p.ID, err)
						failed++
						continue
					}
					fmt.Printf("  %-22s v%s → v%s updated\n", p.ID, p.Version, rp.Version)
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
				fmt.Printf("%d to update, %d up to date, %d not in registry.\n", updated, current, skipped)
				if updated > 0 {
					fmt.Println("Run without --dry-run to apply.")
				}
				return nil
			}

			fmt.Printf("%d updated, %d up to date, %d not in registry, %d failed.\n",
				updated, current, skipped, failed)
			if updated > 0 {
				fmt.Println("Reload the runner to load the new versions: sudo systemctl reload emisar")
			}
			if failed > 0 {
				return fmt.Errorf("%d pack(s) failed to update", failed)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&registry, "registry", "", "pack registry base URL (default $EMISAR_PACKS_REGISTRY or "+defaultRegistry+")")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "report what would change without updating")
	return cmd
}

// updateOnePack fetches id from the registry, verifies it validates and its
// hash matches the index, then atomically swaps it into dir: stage into a
// sibling temp dir and rename, so a failed copy never leaves a broken pack.
func updateOnePack(ctx context.Context, id, dir, registry string, rp registryPack) error {
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

	target := filepath.Join(dir, id)
	staging := target + ".tmp-update"
	_ = os.RemoveAll(staging)
	if err := copyTree(src, staging); err != nil {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("stage updated pack: %w", err)
	}
	if err := os.RemoveAll(target); err != nil {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("remove old pack: %w", err)
	}
	if err := os.Rename(staging, target); err != nil {
		return fmt.Errorf("swap in updated pack: %w", err)
	}
	return nil
}

// fetchPackIndex GETs the registry's /packs.json and returns it keyed by id.
func fetchPackIndex(ctx context.Context, registry string) (map[string]registryPack, error) {
	url := strings.TrimRight(registry, "/") + "/packs.json"
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
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
