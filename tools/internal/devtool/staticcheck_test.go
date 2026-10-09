package devtool

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeStaticcheckFixture(t *testing.T, root string) string {
	t.Helper()
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", canonical)
	t.Setenv("TMP", canonical)
	t.Setenv("TEMP", canonical)
	tools := filepath.Join(root, "tools")
	cache := filepath.Join(root, "cache")
	if err := os.MkdirAll(tools, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(filepath.Join(cache, staticcheckCallFile)), 0o755); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile("testdata/staticcheck/classify_call.go.original")
	if err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string][]byte{
		filepath.Join(tools, "go.mod"):            []byte("module example.com/tools\ngo 1.27.2\n"),
		filepath.Join(tools, "go.sum"):            []byte("fixture checksums\n"),
		filepath.Join(cache, staticcheckCallFile): original,
		filepath.Join(cache, "go.mod"):            []byte("module honnef.co/go/tools\n"),
	} {
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	info, err := json.Marshal(staticcheckModuleInfo{Path: staticcheckModule, Version: staticcheckRelease, Dir: cache})
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("STATICCHECK_MODULE_INFO", string(info))
	t.Setenv("STATICCHECK_DOWNLOAD_INFO", string(info))
	t.Setenv("STATICCHECK_IMPORTER_INFO", `{"Path":"golang.org/x/tools","Version":"v0.50.0"}`)
	t.Setenv("STATICCHECK_GOROOT", root)
	return cache
}

const fakeStaticcheckGo = `case "$1" in
env) printf '%s\n' "$STATICCHECK_GOROOT" ;;
list)
  if [ "$5" = 'golang.org/x/tools' ]; then printf '%s\n' "$STATICCHECK_IMPORTER_INFO"
  else printf '%s\n' "$STATICCHECK_MODULE_INFO"; fi
  ;;
mod)
  case "$2" in
  download) printf '%s\n' "$STATICCHECK_DOWNLOAD_INFO" ;;
  edit) printf '\n// private replacement fixture\n' >> go.mod ;;
  esac
  ;;
build)
  if [ "$2" = '-mod=readonly' ]; then
    if [ "$GOWORK" != off ] || [ "$GOTOOLCHAIN" != local ]; then exit 19; fi
    if [ "${STATICCHECK_BUILD_FAIL:-}" = yes ]; then exit 23; fi
    printf '%s\n' '#!/bin/sh' 'printf "%s|staticcheck|%s|%s|%s\n" "$PWD" "$*" "$GOWORK" "$GOTOOLCHAIN" >> "$COMMAND_LOG"' 'exit "${STATICCHECK_ANALYSIS_EXIT:-0}"' > "$5"
    /bin/chmod +x "$5"
  fi
  ;;
esac
`

func staticcheckTestApp(t *testing.T) (*App, string, string) {
	t.Helper()
	root := t.TempDir()
	cache := writeStaticcheckFixture(t, root)
	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "commands.log")
	t.Setenv("COMMAND_LOG", log)
	t.Setenv("PATH", bin)
	goScript := "#!/bin/sh\nprintf '%s|go|%s\\n' \"$PWD\" \"$*\" >> \"$COMMAND_LOG\"\n" + fakeStaticcheckGo
	if err := os.WriteFile(filepath.Join(bin, "go"), []byte(goScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{}), cache, log
}

func TestStaticcheckModuleRequiresOfficialPinnedRelease(t *testing.T) {
	tests := []struct{ name, input string }{
		{"invalid JSON", "not JSON"},
		{"different path", `{"Path":"example.com/fork","Version":"v0.8.1"}`},
		{"different release", `{"Path":"honnef.co/go/tools","Version":"v0.8.2"}`},
		{"replacement", `{"Path":"honnef.co/go/tools","Version":"v0.8.1","Replace":{"Dir":"/fork"}}`},
		{"resolution error", `{"Path":"honnef.co/go/tools","Version":"v0.8.1","Error":"missing module"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := decodeStaticcheckModule([]byte(tt.input), staticcheckModule, staticcheckRelease); err == nil {
				t.Fatal("accepted unexpected module")
			}
		})
	}
}

func TestStaticcheckBuildUsesPrivateVerifiedSource(t *testing.T) {
	app, cache, _ := staticcheckTestApp(t)
	original, err := os.ReadFile(filepath.Join(cache, staticcheckCallFile))
	if err != nil {
		t.Fatal(err)
	}
	binary, cleanup, err := app.buildStaticcheck(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	private := filepath.Dir(binary)
	patched, err := os.ReadFile(filepath.Join(private, "source", staticcheckCallFile))
	if err != nil || !bytes.Equal(patched, staticcheckCallSource) {
		t.Fatalf("private backport = %q, %v", patched, err)
	}
	unchanged, err := os.ReadFile(filepath.Join(cache, staticcheckCallFile))
	if err != nil || !bytes.Equal(original, unchanged) {
		t.Fatalf("module cache changed: %v", err)
	}
	manifest, err := os.ReadFile(filepath.Join(app.Root, "tools", "go.mod"))
	if err != nil || strings.Contains(string(manifest), "replacement") {
		t.Fatalf("target manifest changed: %q, %v", manifest, err)
	}
	if bytes.Equal(original, patched) || sha256.Sum256(original) == sha256.Sum256(patched) {
		t.Fatal("backport was not applied")
	}
	cleanup()
	if _, err := os.Stat(private); !os.IsNotExist(err) {
		t.Fatalf("private source survived cleanup: %v", err)
	}
}

func TestStaticcheckColdCacheDownloadsSelectedRelease(t *testing.T) {
	app, _, log := staticcheckTestApp(t)
	t.Setenv("STATICCHECK_MODULE_INFO", `{"Path":"honnef.co/go/tools","Version":"v0.8.1"}`)
	binary, cleanup, err := app.buildStaticcheck(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "|go|mod download -json honnef.co/go/tools@v0.8.1") || binary == "" {
		t.Fatalf("cold cache commands = %s", data)
	}
}

func TestStaticcheckBuildFailuresStopAnalysisAndCleanUp(t *testing.T) {
	for _, failure := range []string{"compiler", "hash", "metadata", "missing directory", "importer release", "importer replacement", "build", "verify"} {
		t.Run(failure, func(t *testing.T) {
			app, cache, log := staticcheckTestApp(t)
			switch failure {
			case "compiler":
				t.Setenv("STATICCHECK_GOROOT", "")
			case "hash":
				if err := os.WriteFile(filepath.Join(cache, staticcheckCallFile), []byte("changed"), 0o644); err != nil {
					t.Fatal(err)
				}
			case "metadata":
				t.Setenv("STATICCHECK_MODULE_INFO", "not JSON")
			case "missing directory":
				t.Setenv("STATICCHECK_MODULE_INFO", `{"Path":"honnef.co/go/tools","Version":"v0.8.1"}`)
				t.Setenv("STATICCHECK_DOWNLOAD_INFO", `{"Path":"honnef.co/go/tools","Version":"v0.8.1"}`)
			case "build":
				t.Setenv("STATICCHECK_BUILD_FAIL", "yes")
			case "importer release":
				t.Setenv("STATICCHECK_IMPORTER_INFO", `{"Path":"golang.org/x/tools","Version":"v0.51.0"}`)
			case "importer replacement":
				t.Setenv("STATICCHECK_IMPORTER_INFO", `{"Path":"golang.org/x/tools","Version":"v0.50.0","Replace":{"Dir":"/fork"}}`)
			case "verify":
				path := filepath.Join(app.Root, "bin", "go")
				data, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				data = bytes.Replace(data, []byte("case \"$2\" in"), []byte("case \"$2\" in\n  verify) exit 24 ;;"), 1)
				if err := os.WriteFile(path, data, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			if err := app.runStaticcheck(t.Context(), app.Root, "./..."); err == nil {
				t.Fatal("analysis accepted build failure")
			}
			data, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(data), "|staticcheck|") {
				t.Fatal("analyzer ran after build failure")
			}
			private, err := filepath.Glob(filepath.Join(app.Root, "emisar-staticcheck-*"))
			if err != nil || len(private) != 0 {
				t.Fatalf("failed build directories survived: %v, %v", private, err)
			}
		})
	}
}

func TestStaticcheckAnalysisPreservesTargetEnvironmentAndFailure(t *testing.T) {
	app, _, log := staticcheckTestApp(t)
	t.Setenv("GOWORK", "/analysis/workspace/go.work")
	t.Setenv("GOTOOLCHAIN", "auto")
	t.Setenv("STATICCHECK_ANALYSIS_EXIT", "27")
	if err := app.runStaticcheck(t.Context(), app.Root, "./..."); err == nil || ExitCode(err) != 27 {
		t.Fatalf("analyzer exit = %v", err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "|staticcheck|./...|/analysis/workspace/go.work|auto") {
		t.Fatalf("analysis environment changed: %s", data)
	}
	private, err := filepath.Glob(filepath.Join(app.Root, "emisar-staticcheck-*"))
	if err != nil || len(private) != 0 {
		t.Fatalf("failed analysis directories survived: %v, %v", private, err)
	}
}

// This builds and invokes the real released analyzers, not a shim or --version.
// It is part of the tooling gate so importer/analyzer regressions cannot pass
// on a stale cached command or on mocked success alone.
func TestStaticcheckActualAnalyzersAndExportV5(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOWORK", "off") // The fixture is its own module, outside the checkout.
	var output bytes.Buffer
	app := New(root, strings.NewReader(""), &output, &output)
	goRoot, err := app.output(t.Context(), filepath.Join(root, "tools"), map[string]string{"GOTOOLCHAIN": "local"}, "go", "env", "GOROOT")
	if err != nil {
		t.Fatal(err)
	}
	// This test intentionally analyzes a module outside the checkout. Its
	// compiler and go/packages child must not depend on a version-manager's
	// global fallback; production analysis still preserves its target env.
	t.Setenv("PATH", filepath.Join(strings.TrimSpace(string(goRoot)), "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	binary, cleanup, err := app.buildStaticcheck(t.Context())
	if err != nil {
		t.Fatalf("build: %v\n%s", err, output.String())
	}
	defer cleanup()
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "dep"), 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"go.mod": "module example.com/probe\ngo 1.27.2\n",
		"dep/dep.go": `// Package dep supplies freshly compiled mixed method export data.
package dep

// Mixed has both a generic method and an ordinary method.
type Mixed struct { Value int }
// A returns its input.
func (m Mixed) A[T any](v T) T { return v }
// Z returns the stored value.
func (m Mixed) Z() int { return m.Value }
`,
		"probe.go": `// Package probe exercises classification and export importing.
package probe
import (
 "bytes"
 "math/bits"
 "example.com/probe/dep"
)
// Identity returns its input.
func Identity[T any](v T) T { return v }
// Caller has a dynamically dispatched method.
type Caller interface { Call() int }
// Exercise calls generic functions, interfaces, function values and builtins.
func Exercise(c Caller, f func() int, fs []func() int, n int) int {
 m := dep.Mixed{Value:n}
 return Identity[int](m.Z()) + c.Call() + f() + fs[0]() + min(n, 2) +
 int(byte(n)) + bytes.Count([]byte("abc"), []byte("a")) + bits.OnesCount(uint(n))
}
`,
	}
	for name, source := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(source), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := app.run(t.Context(), dir, nil, "go", "test", "./..."); err != nil {
		t.Fatalf("fresh compiler fixture: %v\n%s", err, output.String())
	}
	output.Reset()
	if err := app.run(t.Context(), dir, nil, binary, "./..."); err != nil {
		t.Fatalf("clean V5/classification fixture: %v\n%s", err, output.String())
	}
	bad := `package probe
import "errors"
// Same deliberately compares an expression with itself.
func Same(v int) bool { return v == v }
// Simplify deliberately compares a bool with a constant.
func Simplify(v bool) bool { if v == true { return true }; return false }
// BadError deliberately violates error-string style.
func BadError() error { return errors.New("Bad thing happened.") }
func deadUnused() {}
`
	if err := os.WriteFile(filepath.Join(dir, "bad.go"), []byte(bad), 0o644); err != nil {
		t.Fatal(err)
	}
	// This separate SA4000 exists only in a test file, proving default test
	// analysis has not been disabled to make the compatibility check pass.
	if err := os.WriteFile(filepath.Join(dir, "probe_test.go"), []byte("package probe\nimport \"testing\"\nfunc TestSame(t *testing.T) { v:=len(t.Name()); if v==v { t.Log(v) } }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := app.run(t.Context(), dir, nil, binary, "./..."); err == nil {
		t.Fatal("real analyzers accepted deliberately invalid fixture")
	}
	for _, diagnostic := range []string{"(S1002)", "(SA4000)", "(ST1005)", "(U1000)", "probe_test.go"} {
		if !strings.Contains(output.String(), diagnostic) {
			t.Errorf("missing %s in real analyzer output:\n%s", diagnostic, output.String())
		}
	}
}
