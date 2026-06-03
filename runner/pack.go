package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

func packCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "pack", Short: "Manage action packs"}
	cmd.AddCommand(packListCmd())
	cmd.AddCommand(packValidateCmd())
	cmd.AddCommand(packInstallCmd())
	return cmd
}

// resolvePackDirs picks the pack search dirs for read-only pack commands.
// `--packs-dir` wins so `emisar pack list --packs-dir ...` works without a
// full config; otherwise we read config.Paths.Packs.
func resolvePackDirs() ([]string, error) {
	if len(flagPacksDir) > 0 {
		return flagPacksDir, nil
	}
	if flagConfig == "" {
		return nil, fmt.Errorf("provide --packs-dir or --config")
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, err
	}
	return cfg.Paths.Packs, nil
}

func packListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List installed packs",
		RunE: func(cmd *cobra.Command, _ []string) error {
			dirs, err := resolvePackDirs()
			if err != nil {
				return err
			}
			reg, err := packs.LoadAll(dirs, packs.LoadOptions{})
			if err != nil {
				return err
			}
			ps := reg.Packs()
			if flagJSONOut {
				return printJSON(ps)
			}
			tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tVERSION\tACTIONS\tHASH\tDESCRIPTION")
			for _, p := range ps {
				actions := 0
				for _, a := range reg.Actions() {
					if a.PackID == p.ID {
						actions++
					}
				}
				hash, _ := reg.PackHash(p.ID)
				fmt.Fprintf(tw, "%s\t%s\t%d\t%s\t%s\n", p.ID, p.Version, actions, shortHash(hash), p.Description)
			}
			return tw.Flush()
		},
	}
}

func packValidateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate <path>",
		Short: "Validate a pack on disk without loading it into the runner",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := packs.LoadOne(args[0], packs.LoadOptions{})
			if err != nil {
				return err
			}
			pack := reg.Packs()[0]
			hash, _ := reg.PackHash(pack.ID)
			fmt.Printf("pack %s OK: %d actions\nhash: %s\n",
				pack.ID, len(reg.Actions()), hash)
			return nil
		},
	}
}

func packInstallCmd() *cobra.Command {
	var (
		wantHash string
		dest     string
		force    bool
	)
	cmd := &cobra.Command{
		Use:   "install <path>",
		Short: "Validate a pack, verify its hash, and copy it into the packs dir",
		Long: `Install a pack from a local directory into the runner's packs dir.

The pack is validated (same checks as 'pack validate') and its content
hash is computed. If --hash is given, the install aborts unless the
computed hash matches exactly — this pins the install to the exact pack
content the portal advertised, so a tampered or mismatched copy is
rejected before it ever reaches the runner.

The pack is copied to <dest>/<pack-id>. After install, reload the runner
(systemctl reload emisar, or SIGHUP) so it re-reads the catalog.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			src := args[0]

			reg, err := packs.LoadOne(src, packs.LoadOptions{})
			if err != nil {
				return err
			}
			pack := reg.Packs()[0]
			gotHash, _ := reg.PackHash(pack.ID)

			if wantHash != "" {
				if !hashEqual(wantHash, gotHash) {
					return fmt.Errorf(
						"hash mismatch for pack %q:\n  expected %s\n  got      %s\nrefusing to install",
						pack.ID, normalizeHash(wantHash), gotHash)
				}
			}

			// Resolve destination packs dir. --dest wins; else first
			// config.Paths.Packs entry. We don't fall back to a default
			// dir — installing into the wrong place silently is worse
			// than asking.
			if dest == "" {
				dirs, err := resolvePackDirs()
				if err != nil {
					return fmt.Errorf("no --dest and %w", err)
				}
				if len(dirs) == 0 {
					return fmt.Errorf("config has no paths.packs entry; pass --dest")
				}
				dest = dirs[0]
			}

			target := filepath.Join(dest, pack.ID)
			if _, err := os.Stat(target); err == nil {
				if !force {
					return fmt.Errorf("pack %q already installed at %s (pass --force to overwrite)", pack.ID, target)
				}
				if err := os.RemoveAll(target); err != nil {
					return fmt.Errorf("remove existing %s: %w", target, err)
				}
			}

			if err := os.MkdirAll(dest, 0o755); err != nil {
				return fmt.Errorf("create packs dir %s: %w", dest, err)
			}
			if err := copyTree(src, target); err != nil {
				return fmt.Errorf("copy pack: %w", err)
			}

			fmt.Printf("installed pack %s (%d actions) to %s\nhash: %s\n",
				pack.ID, len(reg.Actions()), target, gotHash)
			fmt.Println("reload the runner to pick it up: sudo systemctl reload emisar")
			return nil
		},
	}
	cmd.Flags().StringVar(&wantHash, "hash", "", "expected pack content hash (sha256:...); install aborts on mismatch")
	cmd.Flags().StringVar(&dest, "dest", "", "destination packs dir (default: config paths.packs[0])")
	cmd.Flags().BoolVar(&force, "force", false, "overwrite an already-installed pack with the same id")
	return cmd
}

// copyTree recursively copies the directory at src into dst. Regular
// files and directories only — symlinks and other irregular entries are
// rejected so an install can't smuggle a link out of the pack tree.
// (LoadOne already validated the pack, but the copy is a separate trust
// boundary, so we re-check here rather than trust the loader.)
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		out := filepath.Join(dst, rel)

		if d.IsDir() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			return os.MkdirAll(out, info.Mode().Perm())
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("refusing to copy non-regular file %s", rel)
		}
		return copyFile(path, out, d)
	})
}

func copyFile(src, dst string, d os.DirEntry) error {
	info, err := d.Info()
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// normalizeHash strips an optional "sha256:" prefix and lowercases.
func normalizeHash(h string) string {
	h = strings.TrimSpace(h)
	h = strings.TrimPrefix(h, "sha256:")
	return strings.ToLower(h)
}

func hashEqual(a, b string) bool {
	return normalizeHash(a) == normalizeHash(b)
}

func shortHash(h string) string {
	const prefix = "sha256:"
	if len(h) > len(prefix)+12 {
		return h[:len(prefix)+12]
	}
	return h
}
