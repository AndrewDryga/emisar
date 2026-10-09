package devtool

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	staticcheckModule          = "honnef.co/go/tools"
	staticcheckRelease         = "v0.8.1"
	staticcheckImporter        = "golang.org/x/tools"
	staticcheckImporterRelease = "v0.50.0"
	staticcheckCallFile        = "internal/xtools-internal/typesinternal/classify_call.go"
	staticcheckOriginalSHA256  = "2cdb89a64e8fbcd62730f1c6a1ea1e68f0ee3311cad9aacaa5d3c42a9ad78952"
)

// This is the one-file compatibility backport documented beside the source.
// Remove it when an aged official release supports Go's export format V5.
//
//go:embed testdata/staticcheck/classify_call.go
var staticcheckCallSource []byte

type staticcheckModuleInfo struct {
	Path    string
	Version string
	Dir     string
	Error   string
	Replace *json.RawMessage
}

func decodeStaticcheckModule(data []byte, path, version string) (staticcheckModuleInfo, error) {
	var module staticcheckModuleInfo
	if err := json.Unmarshal(data, &module); err != nil {
		return module, fmt.Errorf("decoding staticcheck module: %w", err)
	}
	if module.Path != path || module.Version != version || module.Replace != nil || module.Error != "" {
		return module, fmt.Errorf("staticcheck requires unreplaced %s@%s without resolution errors", path, version)
	}
	return module, nil
}

func (a *App) buildStaticcheck(ctx context.Context) (string, func(), error) {
	tmp, err := os.MkdirTemp("", "emisar-staticcheck-")
	if err != nil {
		return "", nil, fmt.Errorf("creating staticcheck build directory: %w", err)
	}
	cleanup := func() { _ = os.RemoveAll(tmp) }
	complete := false
	defer func() {
		if !complete {
			cleanup()
		}
	}()
	// Tool resolution, sums, and the local replacement live only in this owned
	// directory. The target module and shared cache are never patched.
	for _, name := range []string{"go.mod", "go.sum"} {
		data, err := os.ReadFile(filepath.Join(a.Root, "tools", name))
		if err != nil {
			return "", nil, fmt.Errorf("reading staticcheck build %s: %w", name, err)
		}
		if err := os.WriteFile(filepath.Join(tmp, name), data, 0o600); err != nil {
			return "", nil, fmt.Errorf("copying staticcheck build %s: %w", name, err)
		}
	}
	buildEnv := map[string]string{"GOWORK": "off", "GOTOOLCHAIN": "local"}
	// Resolve the installed compiler while inside the checkout. Version-manager
	// shims need its configuration, which is deliberately absent from tmp.
	data, err := a.output(ctx, filepath.Join(a.Root, "tools"), buildEnv, "go", "env", "GOROOT")
	if err != nil {
		return "", nil, err
	}
	goRoot := strings.TrimSpace(string(data))
	if !filepath.IsAbs(goRoot) {
		return "", nil, fmt.Errorf("staticcheck compiler GOROOT is not an absolute path")
	}
	goBinary := filepath.Join(goRoot, "bin", "go")
	if runtime.GOOS == "windows" {
		goBinary += ".exe"
	}
	data, err = a.output(ctx, tmp, buildEnv, goBinary, "list", "-m", "-mod=readonly", "-json", staticcheckModule)
	if err != nil {
		return "", nil, err
	}
	module, err := decodeStaticcheckModule(data, staticcheckModule, staticcheckRelease)
	if err != nil {
		return "", nil, err
	}
	// Download authenticates cached source against committed sums too. Listing
	// alone does not fetch on a cold cache; verify alone trusts the cache ziphash.
	data, err = a.output(ctx, tmp, buildEnv, goBinary, "mod", "download", "-json", staticcheckModule+"@"+staticcheckRelease)
	if err != nil {
		return "", nil, err
	}
	module, err = decodeStaticcheckModule(data, staticcheckModule, staticcheckRelease)
	if err != nil {
		return "", nil, err
	}
	if module.Dir == "" {
		return "", nil, fmt.Errorf("staticcheck source directory is missing")
	}
	// A require is only an MVS minimum. Fail closed if another tool silently
	// raises or replaces the importer beyond the release this backport covers.
	data, err = a.output(ctx, tmp, buildEnv, goBinary, "list", "-m", "-mod=readonly", "-json", staticcheckImporter)
	if err != nil {
		return "", nil, err
	}
	if _, err := decodeStaticcheckModule(data, staticcheckImporter, staticcheckImporterRelease); err != nil {
		return "", nil, err
	}
	if err := a.run(ctx, tmp, buildEnv, goBinary, "mod", "verify"); err != nil {
		return "", nil, fmt.Errorf("verifying staticcheck build modules: %w", err)
	}
	original, err := os.ReadFile(filepath.Join(module.Dir, staticcheckCallFile))
	if err != nil {
		return "", nil, fmt.Errorf("reading staticcheck compatibility source: %w", err)
	}
	if got := fmt.Sprintf("%x", sha256.Sum256(original)); got != staticcheckOriginalSHA256 {
		return "", nil, fmt.Errorf("staticcheck compatibility source hash %s does not match %s", got, staticcheckOriginalSHA256)
	}
	source := filepath.Join(tmp, "source")
	if err := os.CopyFS(source, os.DirFS(module.Dir)); err != nil {
		return "", nil, fmt.Errorf("copying verified staticcheck source: %w", err)
	}
	if err := os.WriteFile(filepath.Join(source, staticcheckCallFile), staticcheckCallSource, 0o644); err != nil {
		return "", nil, fmt.Errorf("writing staticcheck compatibility source: %w", err)
	}
	replacement := "-replace=" + staticcheckModule + "@" + staticcheckRelease + "=" + source
	if err := a.run(ctx, tmp, buildEnv, goBinary, "mod", "edit", replacement); err != nil {
		return "", nil, err
	}
	binary := filepath.Join(tmp, "staticcheck")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	fmt.Fprintf(a.Out, "Staticcheck %s, x/tools %s, compatibility source SHA256 %x\n", staticcheckRelease, staticcheckImporterRelease, sha256.Sum256(staticcheckCallSource))
	if err := a.run(ctx, tmp, buildEnv, goBinary, "build", "-mod=readonly", "-trimpath", "-o", binary, staticcheckModule+"/cmd/staticcheck"); err != nil {
		return "", nil, fmt.Errorf("building staticcheck: %w", err)
	}
	complete = true
	return binary, cleanup, nil
}

func (a *App) runStaticcheck(ctx context.Context, dir string, args ...string) error {
	binary, cleanup, err := a.buildStaticcheck(ctx)
	if err != nil {
		return err
	}
	defer cleanup()
	// Restore the target's normal workspace/environment for analysis; the
	// build-only GOWORK=off must not change what packages the gate analyzes.
	return a.run(ctx, dir, nil, binary, args...)
}
