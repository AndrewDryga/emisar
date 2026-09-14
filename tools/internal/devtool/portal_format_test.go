package devtool

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The umbrella shape the cached dot formatter is resolved against: a root
// configuration that owns its own inputs and delegates everything under apps/ to
// each app's own .formatter.exs, exactly as portal/.formatter.exs does.
const (
	probeUmbrellaMix = `defmodule Probe.Umbrella.MixProject do
  use Mix.Project

  def project, do: [apps_path: "apps", version: "0.0.1"]
end
`
	probeAppMix = `defmodule Probe.MixProject do
  use Mix.Project

  def project, do: [app: :probe, version: "0.0.1"]
end
`
	probeUmbrellaFormatter = `[
  inputs: ["mix.exs"],
  subdirectories: ["apps/*"]
]
`
	probeAppFormatter = `[
  inputs: ["{lib,test}/**/*.{ex,exs}"]
]
`
	probeFormatted    = "defmodule Probe do\n  def value(x) do\n    x\n  end\nend\n"
	probeMisformatted = "defmodule Probe do\ndef  value( x ) do\n    x\n  end\nend\n"
)

func writePortalFormatFixture(t *testing.T, root, appSource string) {
	t.Helper()
	for path, source := range map[string]string{
		"portal/mix.exs":                        probeUmbrellaMix,
		"portal/.formatter.exs":                 probeUmbrellaFormatter,
		"portal/apps/probe/mix.exs":             probeAppMix,
		"portal/apps/probe/.formatter.exs":      probeAppFormatter,
		"portal/apps/probe/lib/probe.ex":        appSource,
		"portal/apps/probe/test/probe_test.exs": probeFormatted,
	} {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(source), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// runMixFormat runs mix in root/portal against a build and deps root the caller
// owns, so the cached dot formatter under test is the only one in play.
func runMixFormat(t *testing.T, root, buildRoot, depsPath string, args ...string) (int, string) {
	t.Helper()
	command := exec.CommandContext(t.Context(), "mix", args...)
	command.Dir = filepath.Join(root, "portal")
	// Drop every inherited MIX_* setting first: a coop box exports the shared
	// MIX_BUILD_ROOT this test is about, and an empty MIX_BUILD_PATH counts as set.
	env := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "MIX_") {
			env = append(env, entry)
		}
	}
	command.Env = append(env,
		"MIX_BUILD_ROOT="+buildRoot,
		"MIX_DEPS_PATH="+depsPath,
		"MIX_ENV=dev",
	)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	var code int
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatalf("mix %v: %v: %s", args, err, output.String())
		}
		code = exit.ExitCode()
	}
	return code, output.String()
}

// A green `./run gate portal` once handed the commit hook two unformatted app
// files, which it then refused. Mix caches the resolved :subdirectories config in
// <build root>/dev/.mix/cached_dot_formatter by ABSOLUTE path, and a coop box
// shares one MIX_BUILD_ROOT across checkouts: a manifest another checkout wrote
// outlives it, its apps/* paths expand to nothing rather than to something stale,
// so the entry never looks stale and a bare `mix format --check-formatted`
// silently checks the umbrella's own inputs only.
//
// This reproduces that exactly — one checkout writes the manifest, is deleted, and
// a second checkout inherits it — and pins that the argv every Portal format check
// is built from still sees a deliberately misformatted app source.
//
// Requires mix. The tools CI job installs Go and shellcheck only, so this pin runs
// on contributor machines and coop boxes rather than in CI.
func TestMixFormatArgsSeeAppSourcesUnderAForeignCachedDotFormatter(t *testing.T) {
	if _, err := exec.LookPath("mix"); err != nil {
		t.Skip("mix is not on PATH")
	}
	base := t.TempDir()
	buildRoot := filepath.Join(base, "build")
	depsPath := filepath.Join(base, "deps")

	// The checkout that poisons the shared cache: formatted, so it passes and
	// records its own absolute apps/* paths in the manifest.
	first := filepath.Join(base, "first")
	writePortalFormatFixture(t, first, probeFormatted)
	if code, output := runMixFormat(t, first, buildRoot, depsPath, "format", "--check-formatted"); code != 0 {
		t.Fatalf("seeding run exited %d, want 0: %s", code, output)
	}
	manifest := filepath.Join(buildRoot, "dev", ".mix", "cached_dot_formatter")
	if _, err := os.Stat(manifest); err != nil {
		t.Fatalf("mix wrote no cached dot formatter, so this pins nothing: %v", err)
	}
	if err := os.RemoveAll(first); err != nil {
		t.Fatal(err)
	}

	second := filepath.Join(base, "second")
	writePortalFormatFixture(t, second, probeMisformatted)
	app := New(second, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})

	if code, output := runMixFormat(t, second, buildRoot, depsPath, "format", "--check-formatted"); code != 0 {
		t.Logf("bare `mix format --check-formatted` now catches app sources; if Mix "+
			"stopped reusing a foreign cached dot formatter, the --dot-formatter in "+
			"mixFormatArgs can be revisited: %s", output)
	}

	code, output := runMixFormat(t, second, buildRoot, depsPath, app.mixFormatArgs("--check-formatted")...)
	if code == 0 {
		t.Fatalf("the Portal format argv passed an unformatted app source: %s", output)
	}
	if !strings.Contains(output, filepath.Join("apps", "probe", "lib", "probe.ex")) {
		t.Fatalf("format failure did not name the unformatted app source: %s", output)
	}

	// And it still passes a clean tree, so the coverage it regained is not noise.
	if err := os.WriteFile(filepath.Join(second, "portal", "apps", "probe", "lib", "probe.ex"),
		[]byte(probeFormatted), 0o644); err != nil {
		t.Fatal(err)
	}
	if code, output := runMixFormat(t, second, buildRoot, depsPath, app.mixFormatArgs("--check-formatted")...); code != 0 {
		t.Fatalf("the Portal format argv exited %d on a formatted tree: %s", code, output)
	}
}
