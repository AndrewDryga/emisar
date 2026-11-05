package devtool

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// sharedBuildRootEnv remembers the image's shared MIX_BUILD_ROOT once a run has
// keyed it, so a nested ./run inherits the keyed root instead of keying twice.
const sharedBuildRootEnv = "EMISAR_SHARED_MIX_BUILD_ROOT"

// isolateBoxBuildRoot gives each checkout its own Mix build directory inside a
// Coop box. The box image points MIX_BUILD_ROOT at one cache-volume path, which
// every checkout's box mounts: parallel forks would otherwise compile different
// source trees into one _build, contending for its lock and leaving manifests
// that serve stale modules. The tool binaries Mix packages download next to the
// build root (tailwind, esbuild) are linked in, because a filtered box cannot
// download them again.
func (a *App) isolateBoxBuildRoot() error {
	if !a.inBox() {
		return nil
	}
	shared := os.Getenv(sharedBuildRootEnv)
	if shared == "" {
		shared = os.Getenv("MIX_BUILD_ROOT")
	}
	if shared == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(filepath.Clean(a.Root)))
	keyed := filepath.Join(shared, "checkouts", hex.EncodeToString(sum[:6]))
	if err := os.MkdirAll(keyed, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(shared)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !(strings.HasPrefix(name, "tailwind-") || strings.HasPrefix(name, "esbuild-")) {
			continue
		}
		link := filepath.Join(keyed, name)
		if err := os.Symlink(filepath.Join(shared, name), link); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	if err := os.Setenv(sharedBuildRootEnv, shared); err != nil {
		return err
	}
	return os.Setenv("MIX_BUILD_ROOT", keyed)
}
