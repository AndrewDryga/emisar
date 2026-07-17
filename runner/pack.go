package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// defaultRegistry is the pack registry the runner fetches named packs
// from. Override with --registry or EMISAR_PACKS_REGISTRY.
const defaultRegistry = "https://emisar.dev"

func packCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "pack",
		Aliases: []string{"packs"},
		Short:   "Manage action packs",
		Long: `Packs are the runner's action catalog: versioned bundles of action schemas
this host may execute. Install them from a registry — the public one at
https://emisar.dev by default, or your own (--registry / EMISAR_PACKS_REGISTRY;
any static host serving the registry layout works). Installs can pin an exact
content hash with --hash, and the runner always re-hashes packs on load.

Author your own packs and host a private registry with packctl — the same tool
that builds and publishes the public registry. Guide:
https://emisar.dev/docs/pack-registry`,
		Example: `  # See what fits this host, then install with the hash the portal advertises
  emisar pack suggest
  emisar pack install redis --hash sha256:...

  # Install from YOUR registry (or set EMISAR_PACKS_REGISTRY)
  emisar pack install billing-tools --registry https://packs.acme.internal --hash sha256:...

  # Validate a pack you're authoring
  emisar pack validate ./my-pack`,
	}
	cmd.AddGroup(
		&cobra.Group{ID: "install", Title: "Discover & install:"},
		&cobra.Group{ID: "installed", Title: "Installed packs:"},
		&cobra.Group{ID: "author", Title: "Author:"},
	)
	add := func(groupID string, c *cobra.Command) {
		c.GroupID = groupID
		cmd.AddCommand(c)
	}
	add("install", packSuggestCmd())
	add("install", packInstallCmd())
	add("install", packUpdateCmd())
	add("installed", packListCmd())
	add("installed", packInfoCmd())
	add("installed", packUninstallCmd())
	add("author", packValidateCmd())
	return cmd
}

// configInheritEnv returns the runner's inherit_env allowlist and whether
// a config was actually resolved. Best-effort: pack info/install still
// render without it — we just skip the "missing from inherit_env" check.
func configInheritEnv() (env []string, ok bool) {
	cfgPath, err := resolveConfigPath()
	if err != nil {
		return nil, false
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return nil, false
	}
	return cfg.Execution.InheritEnv, true
}

// resolvePackDirs picks the pack search dirs for read-only pack commands.
// `--packs-dir` wins so `emisar pack list --packs-dir ...` works without a
// full config; otherwise we read config.Paths.Packs.
func resolvePackDirs() ([]string, error) {
	if len(flagPacksDir) > 0 {
		return flagPacksDir, nil
	}
	cfgPath, err := resolveConfigPath()
	if err != nil {
		return nil, fmt.Errorf("provide --packs-dir, or %w", err)
	}
	cfg, err := config.Load(cfgPath)
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

func packInfoCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "info <id>",
		Short: "Show how to make an installed pack work (setup, auth, action profile)",
		Long: `Print a pack's setup requirements and action profile: what it does,
its risk breakdown, required binaries (with a live PATH check), the
environment variables its tool reads to authenticate, and a command to
verify it can reach its target.

This is the same summary 'pack install' prints after a successful
install. Resolves the pack from the configured packs dirs (or --packs-dir).
Once a config is found (auto-discovered, or via --config), it also flags
any required env var missing from the runner's inherit_env allowlist.`,
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			dirs, err := resolvePackDirs()
			if err != nil {
				return err
			}
			reg, err := packs.LoadAll(dirs, packs.LoadOptions{})
			if err != nil {
				return err
			}
			pack, ok := reg.Pack(args[0])
			if !ok {
				return fmt.Errorf("pack %q not installed (looked in %s)", args[0], strings.Join(dirs, ", "))
			}
			if flagJSONOut {
				return printJSON(pack)
			}
			env, haveCfg := configInheritEnv()
			writePackInfo(os.Stdout, reg, pack, env, haveCfg)
			return nil
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

			// Lint: non-fatal advisories (e.g. a secret-looking arg not marked
			// sensitive). Printed to stderr so the "OK" line + hash on stdout
			// stay machine-parseable.
			for _, action := range reg.Actions() {
				for _, w := range action.SecretArgWarnings() {
					fmt.Fprintf(os.Stderr, "warning: %s\n", w)
				}
			}

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
		registry string
		force    bool
	)
	cmd := &cobra.Command{
		Use:   "install <name|path|url>",
		Short: "Fetch/validate a pack, verify its hash, and copy it into the packs dir",
		Long: `Install a single action pack into the runner's packs dir.

The source can be:

  * a pack name      (e.g. "redis") — fetched from the registry at
                     <registry>/packs/<name>/pack.tar.gz
  * name=version     (e.g. "redis=0.2.3") — a specific published version at
                     <registry>/packs/<name>/versions/<version>/pack.tar.gz
  * a local directory (e.g. "./my-pack" or an absolute path)
  * an https:// URL  to a pack tarball

The pack is validated (same checks as 'pack validate') and its content
hash is computed. If --hash is given, the install aborts unless the
computed hash matches exactly — this pins the install to the exact pack
content the portal advertised, so a tampered or mismatched copy is
rejected before it reaches the runner.

The pack is copied to <dest>/<pack-id>. A running daemon is reloaded
automatically (SIGHUP) so it re-reads the catalog and re-advertises;
without one, reload manually: systemctl reload emisar.

  emisar pack install redis --dest /etc/emisar/packs
  emisar pack install redis=0.2.3 --hash sha256:... --dest /etc/emisar/packs
  emisar pack install redis --hash sha256:... --dest /etc/emisar/packs
  emisar pack install ./my-pack --dest /etc/emisar/packs`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			arg := args[0]
			if registry == "" {
				registry = os.Getenv("EMISAR_PACKS_REGISTRY")
			}
			if registry == "" {
				registry = defaultRegistry
			}

			src, cleanup, err := resolvePackSource(cmd.Context(), arg, registry)
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
			if err := replacePackTree(src, target, force); err != nil {
				return err
			}

			fmt.Printf("installed %s → %s\n", pack.ID, target)
			env, haveCfg := configInheritEnv()
			writePackInfo(os.Stdout, reg, pack, env, haveCfg)
			fmt.Println()
			announceReload(os.Stdout, nil, "Reload the runner to load it: sudo systemctl reload emisar")
			return nil
		},
	}
	cmd.Flags().StringVar(&wantHash, "hash", "", "expected pack content hash (sha256:...); install aborts on mismatch")
	cmd.Flags().StringVar(&dest, "dest", "", "destination packs dir (default: config paths.packs[0])")
	cmd.Flags().StringVar(&registry, "registry", "", "pack registry base URL for named packs (default $EMISAR_PACKS_REGISTRY or "+defaultRegistry+")")
	cmd.Flags().BoolVar(&force, "force", false, "overwrite an already-installed pack with the same id")
	return cmd
}

// resolvePackSource turns the install argument into a local directory
// containing the pack. A local path is returned as-is (no cleanup); a
// name or URL is fetched + extracted to a temp dir (cleanup removes it).
func resolvePackSource(ctx context.Context, arg, registry string) (dir string, cleanup func(), err error) {
	switch {
	case strings.HasPrefix(arg, "https://") || strings.HasPrefix(arg, "http://"):
		banner("fetching pack from %s", arg)
		return packs.Fetch(ctx, arg, nil)
	case looksLikeLocalPath(arg):
		return arg, nil, nil
	default:
		base := strings.TrimRight(registry, "/")
		// name=version pins a specific published version; a bare name resolves
		// to the current one. Split on the FIRST '=' only (checked after the
		// local-path case, so a path containing '=' still resolves as a path).
		if name, version, versioned := strings.Cut(arg, "="); versioned {
			if !packspec.ValidPackID(name) || !packspec.ValidVersion(version) {
				return "", nil, fmt.Errorf("invalid pack spec %q: expected <name>=<version> with a valid pack id and version", arg)
			}
			url := fmt.Sprintf("%s/packs/%s/versions/%s/pack.tar.gz", base, name, version)
			banner("fetching pack %q version %s from %s", name, version, base)
			return packs.Fetch(ctx, url, nil)
		}
		// Bare name → current-version registry URL.
		url := fmt.Sprintf("%s/packs/%s/pack.tar.gz", base, arg)
		banner("fetching pack %q from %s", arg, base)
		return packs.Fetch(ctx, url, nil)
	}
}

// looksLikeLocalPath reports whether arg should be treated as a path on
// disk rather than a registry pack name. Anything with a separator, a
// leading dot, or that resolves to an existing directory is a path;
// a bare token like "redis" is a registry name.
func looksLikeLocalPath(arg string) bool {
	if strings.ContainsRune(arg, '/') || strings.ContainsRune(arg, os.PathSeparator) {
		return true
	}
	if arg == "." || arg == ".." || strings.HasPrefix(arg, ".") {
		return true
	}
	if fi, err := os.Stat(arg); err == nil && fi.IsDir() {
		return true
	}
	return false
}

func packUninstallCmd() *cobra.Command {
	var dest string
	cmd := &cobra.Command{
		Use:     "uninstall <name>",
		Aliases: []string{"remove", "rm", "delete"},
		Short:   "Remove an installed pack from the packs dir",
		Long: `Delete a pack from the runner's packs dir by id.

Resolves the destination the same way 'pack install' does (--dest, else
config paths.packs[0]) and removes <dest>/<name>. A running daemon is
reloaded automatically (SIGHUP) so it drops the pack's actions from the
advertised catalog; without one, reload manually: systemctl reload emisar.

  emisar pack uninstall redis --dest /etc/emisar/packs
  emisar pack rm redis`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			// A pack id must be a single, safe path segment. This is the
			// guard that keeps `uninstall ../../etc` (or an absolute path)
			// from turning into a RemoveAll outside the packs dir.
			if !safePackName(name) {
				return fmt.Errorf("invalid pack name %q (must be a single path segment, no slashes or '..')", name)
			}

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

			target := filepath.Join(dest, name)
			info, err := os.Stat(target)
			if err != nil {
				if os.IsNotExist(err) {
					return fmt.Errorf("pack %q is not installed at %s", name, target)
				}
				return err
			}
			if !info.IsDir() {
				return fmt.Errorf("%s is not a pack directory", target)
			}

			// Refuse to delete a directory that isn't actually a pack —
			// avoids nuking an unrelated dir if the packs dir was pointed
			// somewhere unexpected.
			if _, err := os.Stat(filepath.Join(target, "pack.yaml")); err != nil {
				return fmt.Errorf("%s has no pack.yaml — refusing to delete (not a pack)", target)
			}

			if err := os.RemoveAll(target); err != nil {
				return fmt.Errorf("remove %s: %w", target, err)
			}

			fmt.Printf("removed pack %s from %s\n", name, target)
			announceReload(os.Stdout, nil, "Reload the runner to drop its actions: sudo systemctl reload emisar")
			return nil
		},
	}
	cmd.Flags().StringVar(&dest, "dest", "", "packs dir the pack lives in (default: config paths.packs[0])")
	return cmd
}

// safePackName reports whether name is a single path segment safe to
// join under the packs dir — no separators, no traversal, not empty/dot.
func safePackName(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	if strings.ContainsRune(name, '/') || strings.ContainsRune(name, os.PathSeparator) {
		return false
	}
	if filepath.IsAbs(name) || name != filepath.Clean(name) {
		return false
	}
	return true
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
			// 0755, not the source dir's mode: a pack fetched over the network
			// lands in an os.MkdirTemp dir (0700), and preserving that would
			// leave the installed pack unreadable to a non-root runner service
			// user whenever `pack install`/`pack update` runs under sudo (the
			// reported "only 2 of N packs loaded" bug). Chmod also defeats a
			// restrictive umask. Pack content is public, so world-readable +
			// traversable is correct.
			if err := os.MkdirAll(out, 0o755); err != nil {
				return err
			}
			return os.Chmod(out, 0o755)
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("refusing to copy non-regular file %s", rel)
		}
		return copyFile(path, out, d)
	})
}

type packTreeRename func(oldPath, newPath string) error

// replacePackTree stages a complete tree beside target before touching the
// active pack. Replacement uses a deterministic backup so an activation error
// rolls back immediately and a later command can recover an interrupted swap.
// It deliberately does not claim crash atomicity across the two renames.
func replacePackTree(src, target string, replace bool) error {
	return replacePackTreeWithRename(src, target, replace, os.Rename)
}

func replacePackTreeWithRename(src, target string, replace bool, rename packTreeRename) error {
	parent := filepath.Dir(target)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return fmt.Errorf("create packs dir %s: %w", parent, err)
	}

	backup := filepath.Join(parent, "."+filepath.Base(target)+".previous")
	targetExists, err := pathExists(target)
	if err != nil {
		return fmt.Errorf("inspect installed pack %s: %w", target, err)
	}
	backupExists, err := pathExists(backup)
	if err != nil {
		return fmt.Errorf("inspect pack backup %s: %w", backup, err)
	}
	if !targetExists && backupExists {
		if err := rename(backup, target); err != nil {
			return fmt.Errorf("restore interrupted pack replacement: %w", err)
		}
		targetExists = true
		backupExists = false
	}
	if targetExists && backupExists {
		if err := os.RemoveAll(backup); err != nil {
			return fmt.Errorf("remove completed pack backup %s: %w", backup, err)
		}
	}
	if targetExists && !replace {
		return fmt.Errorf("pack %q already installed at %s (pass --force to overwrite)", filepath.Base(target), target)
	}

	staging, err := os.MkdirTemp(parent, "."+filepath.Base(target)+".stage-")
	if err != nil {
		return fmt.Errorf("create pack staging directory: %w", err)
	}
	defer os.RemoveAll(staging)
	if err := copyTree(src, staging); err != nil {
		return fmt.Errorf("stage pack: %w", err)
	}

	if targetExists {
		if err := rename(target, backup); err != nil {
			return fmt.Errorf("back up installed pack: %w", err)
		}
	}
	if err := rename(staging, target); err != nil {
		if targetExists {
			if rollbackErr := rename(backup, target); rollbackErr != nil {
				return fmt.Errorf("activate pack: %v; restore previous pack: %w", err, rollbackErr)
			}
		}
		return fmt.Errorf("activate pack: %w", err)
	}
	if targetExists {
		if err := os.RemoveAll(backup); err != nil {
			return fmt.Errorf("remove previous pack backup %s: %w", backup, err)
		}
	}
	return nil
}

func pathExists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
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
	// World-readable (0644), preserving the executable bit for scripts, so the
	// runner's service user can read the pack no matter who installed it. An
	// explicit Chmod after write defeats a restrictive umask.
	mode := os.FileMode(0o644)
	if info.Mode()&0o111 != 0 {
		mode = 0o755
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chmod(dst, mode)
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
