package infraops

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

const diagnosticsRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func diagnosticsFixture(t *testing.T) string {
	t.Helper()
	bundle := t.TempDir()
	commands, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/diagnostics/commands.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"bin", "libexec", "lib", "cli-plugins", "python/lib/python3/dist-packages/ntp"} {
		if err := os.MkdirAll(filepath.Join(bundle, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	files := []string{"run-tool", "lib/loader", "libexec/python3", "cli-plugins/docker-compose", "python/lib/python3/dist-packages/ntp/libntpc.so"}
	for _, command := range strings.Fields(string(commands)) {
		files = append(files, "libexec/"+command)
		if err := os.Symlink("../run-tool", filepath.Join(bundle, "bin", command)); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range files {
		if err := os.WriteFile(filepath.Join(bundle, path), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(bundle, "commands.txt"), commands, 0o600); err != nil {
		t.Fatal(err)
	}
	identity := "fixture-runtime\t1.0-1\tamd64\tfixture-runtime\t1.0-1"
	var origins []string
	for _, path := range append(files, "commands.txt") {
		kind, source, owner := "debian", "/usr/"+path, identity
		switch path {
		case "run-tool", "commands.txt":
			kind, source, owner = "repository", "/build/"+path, "emisar\t"+diagnosticsRevision+"\tall\temisar\t"+diagnosticsRevision
		case "cli-plugins/docker-compose":
			kind, source, owner = "github-release", "https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64", "docker-compose\t5.5.1\tamd64\tdocker/compose\tv5.5.1"
		}
		origins = append(origins, "./"+path+"\t"+kind+"\t"+source+"\t"+owner+"\n")
	}
	sort.Strings(origins)
	for path, data := range map[string]string{
		"debian-runtime.tsv":             identity + "\n",
		"debian-builder.tsv":             identity + "\nlinux-libc-dev\t6.1.1-1\tamd64\tlinux\t6.1.1-1\n",
		"file-origins.tsv":               strings.Join(origins, ""),
		"source-builds.tsv":              "sysstat\t12.6.1-1\tDebian-signed-source; fixture\n",
		"python-installed-identity.json": "{\"abi\":{\"fixture\":true},\"builtins\":[\"sys\",\"pyexpat\",\"_elementtree\"]}\n",
		"python-private-identity.json":   "{\"abi\":{\"fixture\":true},\"builtins\":[\"sys\"]}\n",
		"python-private-build.txt":       "source_version=3.11.2-6+deb12u9\nfixture compiler/config evidence\n",
	} {
		if err := os.WriteFile(filepath.Join(bundle, path), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sealDiagnosticsFixture(t, bundle)
	return bundle
}

func sealDiagnosticsFixture(t *testing.T, bundle string) {
	t.Helper()
	var entries []string
	err := filepath.WalkDir(bundle, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || path == filepath.Join(bundle, "manifest") || path == filepath.Join(bundle, "SHA256SUMS") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(bundle, path)
		if err != nil {
			return err
		}
		entries = append(entries, fmt.Sprintf("%x  ./%s\n", sha256.Sum256(data), filepath.ToSlash(rel)))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(entries)
	sums := []byte(strings.Join(entries, ""))
	if err := os.WriteFile(filepath.Join(bundle, "SHA256SUMS"), sums, 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := fmt.Sprintf("schema=2\npurpose=admin-diagnostics\nos=linux\narchitecture=amd64\nrevision=%s\nchecksums_sha256=%x\ninventory_scope=measured shipped Debian closure; complete builder provenance retained\n", diagnosticsRevision, sha256.Sum256(sums))
	if err := os.WriteFile(filepath.Join(bundle, "manifest"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDiagnosticsManifestRejectsWrongIdentityAndIncompleteClosure(t *testing.T) {
	validator := filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/verify-diagnostics.sh")
	for _, tc := range []struct {
		name string
		edit func(string) error
	}{
		{"valid", nil},
		{"corrupt bytes", func(dir string) error {
			return os.WriteFile(filepath.Join(dir, "libexec/sar"), []byte("corrupt"), 0o700)
		}},
		{"collector absent even after reseal", func(dir string) error {
			err := os.Remove(filepath.Join(dir, "libexec/sadc"))
			sealDiagnosticsFixture(t, dir)
			return err
		}},
		{"libntpc absent even after reseal", func(dir string) error {
			err := os.Remove(filepath.Join(dir, "python/lib/python3/dist-packages/ntp/libntpc.so"))
			sealDiagnosticsFixture(t, dir)
			return err
		}},
		{"omitted file owner even after reseal", func(dir string) error {
			path := filepath.Join(dir, "file-origins.tsv")
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			var rows []string
			for _, row := range strings.Split(string(data), "\n") {
				if !strings.HasPrefix(row, "./libexec/sar\t") {
					rows = append(rows, row)
				}
			}
			err = os.WriteFile(path, []byte(strings.Join(rows, "\n")), 0o600)
			sealDiagnosticsFixture(t, dir)
			return err
		}},
		{"builder-only package declared runtime", func(dir string) error {
			path := filepath.Join(dir, "debian-runtime.tsv")
			file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				return err
			}
			_, err = file.WriteString("linux-libc-dev\t6.1.1-1\tamd64\tlinux\t6.1.1-1\n")
			_ = file.Close()
			sealDiagnosticsFixture(t, dir)
			return err
		}},
		{"nested metadata name is still a payload", func(dir string) error {
			err := os.WriteFile(filepath.Join(dir, "python/manifest"), []byte("unowned payload bytes"), 0o600)
			sealDiagnosticsFixture(t, dir)
			return err
		}},
		{"wrong purpose", func(dir string) error { return replaceFixtureText(dir, "purpose=admin-diagnostics", "purpose=portal") }},
		{"wrong arch", func(dir string) error { return replaceFixtureText(dir, "architecture=amd64", "architecture=arm64") }},
		{"wrong revision", func(dir string) error { return replaceFixtureText(dir, diagnosticsRevision, strings.Repeat("b", 40)) }},
		{"escaping link", func(dir string) error { return os.Symlink("/etc/passwd", filepath.Join(dir, "python/escape")) }},
		{"extra protected command", func(dir string) error { return os.Symlink("../run-tool", filepath.Join(dir, "bin/docker")) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bundle := diagnosticsFixture(t)
			if tc.edit != nil {
				if err := tc.edit(bundle); err != nil {
					t.Fatal(err)
				}
			}
			output, err := exec.Command("bash", validator, bundle, diagnosticsRevision, "amd64").CombinedOutput()
			if (err != nil) != (tc.edit != nil) {
				t.Fatalf("unexpected validation: %v\n%s", err, output)
			}
		})
	}
}

func replaceFixtureText(dir, old, replacement string) error {
	path := filepath.Join(dir, "manifest")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.ReplaceAll(string(data), old, replacement)), 0o600)
}

func TestDiagnosticsQualifierRequiresDockerWithoutAddingGateDependency(t *testing.T) {
	a := New(repositoryRoot(t), nil, nil, nil)
	a.LookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	err := a.Run(context.Background(), []string{"qualify-admin-diagnostics", diagnosticsRevision, "emisar/admin-diagnostics:test"})
	if err == nil || !strings.Contains(err.Error(), "docker is required") {
		t.Fatalf("Docker absence must fail explicit qualification: %v", err)
	}
}

func TestDiagnosticsLinkageRejectsHostFallbackAndMissingLibraries(t *testing.T) {
	for _, tc := range []struct {
		name, listing string
		fail          bool
	}{
		{"private closure", "linux-vdso.so.1 (0x1234)\nlibc.so.6 => $TEST_BUNDLE/lib/libc.so.6 (0x2345)\n$TEST_BUNDLE/lib/loader (0x3456)\n", false},
		{"host fallback", "libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x2345)\n", true},
		{"unresolved library", "libmissing.so => not found\n", true},
		{"host loader", "/lib64/ld-linux-x86-64.so.2 (0x3456)\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bundle := t.TempDir()
			if err := os.Mkdir(filepath.Join(bundle, "lib"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(bundle, "lib/loader"), []byte("#!/bin/sh\ncat <<EOF\n"+tc.listing+"EOF\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TEST_BUNDLE", bundle)
			validator := filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/diagnostics/verify-linkage.sh")
			output, err := exec.Command("bash", validator, bundle, "fixture-ELF").CombinedOutput()
			if (err != nil) != tc.fail {
				t.Fatalf("private dependency check: %v\n%s", err, output)
			}
		})
	}
}

func TestDiagnosticsOwnerLookupRejectsUnknownAndAmbiguousAndFollowsBytes(t *testing.T) {
	temp := t.TempDir()
	owned := filepath.Join(temp, "owned")
	if err := os.WriteFile(owned, []byte("owned bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(owned)
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(temp, "foreign-link")
	if err := os.Symlink(owned, link); err != nil {
		t.Fatal(err)
	}
	query := `#!/bin/bash
set -euo pipefail
case "$1" in
  -S)
    path=${@: -1}
    [ "$path" = "$TEST_OWNED_FILE" ] || exit 1
    case "$TEST_OWNER_MODE" in
      missing) exit 1 ;;
      ambiguous) printf 'runtime: %s\nother: %s\n' "$path" "$path" ;;
      valid) printf 'runtime: %s\n' "$path" ;;
    esac ;;
  -W) printf 'ii \truntime\t1.0-1\tamd64\truntime-source\t1.0-1\n' ;;
  *) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(temp, "dpkg-query"), []byte(query), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", temp+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TEST_OWNED_FILE", canonical)
	validator := filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/diagnostics/inventory.sh")
	for _, mode := range []string{"valid", "missing", "ambiguous"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv("TEST_OWNER_MODE", mode)
			command := exec.Command("bash", "-c", `set -euo pipefail; bundle_root=$1; ownership_rows=$1/origins; source "$2"; diagnostics_debian_owner "$3"`, "owner-test", temp, validator, link)
			output, err := command.CombinedOutput()
			if mode == "valid" {
				if err != nil || string(output) != "runtime\t1.0-1\tamd64\truntime-source\t1.0-1\n" {
					t.Fatalf("target byte ownership was lost: %v\n%s", err, output)
				}
			} else if err == nil {
				t.Fatalf("%s Debian ownership accepted", mode)
			}
		})
	}
}

func TestDiagnosticsNTPWrapperUsesPrivateImmutablePythonConfiguration(t *testing.T) {
	bundle := t.TempDir()
	for _, directory := range []string{"bin", "lib"} {
		if err := os.Mkdir(filepath.Join(bundle, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	source, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/diagnostics/run-tool"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "run-tool"), source, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../run-tool", filepath.Join(bundle, "bin/ntpq")); err != nil {
		t.Fatal(err)
	}
	loader := "#!/bin/sh\nset -eu\n[ -z \"${LD_PRELOAD+x}${LD_LIBRARY_PATH+x}\" ]\nprintf '%s\\n' \"$@\" \"$PYTHONHOME\" \"$PYTHONPATH\"\n"
	if err := os.WriteFile(filepath.Join(bundle, "lib/loader"), []byte(loader), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LD_LIBRARY_PATH", "/hostile")
	t.Setenv("PYTHONHOME", "/hostile")
	t.Setenv("PYTHONPATH", "/hostile")
	output, err := exec.Command(filepath.Join(bundle, "bin/ntpq"), "-pn").CombinedOutput()
	if err != nil {
		t.Fatalf("private launcher: %v\n%s", err, output)
	}
	canonical, err := filepath.EvalSymlinks(bundle)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{"--library-path", canonical + "/lib", canonical + "/libexec/python3", "-B", "-P", "-S", canonical + "/libexec/ntpq", "-pn", canonical + "/python", canonical + "/python/lib/python3/dist-packages", ""}, "\n")
	if string(output) != want {
		t.Fatalf("unsafe Python configuration: %s", output)
	}
}

func TestDiagnosticsQualifierBindIsReadableWithoutCapabilitiesAndCleaned(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(fmt.Sprintf("failure=%t", failure), func(t *testing.T) {
			temp := t.TempDir()
			log := filepath.Join(temp, "docker.log")
			mock := filepath.Join(temp, "docker")
			source := `#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
case "$1" in
  build|cp|rm) ;;
  create) printf 'never-started-container\n' ;;
  run)
    for arg in "$@"; do
      case "$arg" in
        type=bind,src=*,dst=/qualification,readonly)
          staging=${arg#type=bind,src=}; staging=${staging%,dst=/qualification,readonly}
          # No DAC_OVERRIDE: an unrelated UID needs the other read/execute bits.
          [ "$(find "$staging" -maxdepth 0 -perm -0005 -print)" = "$staging" ]
          test -r "$staging/qualify.sh"
          test -r "$staging/verify-diagnostics.sh"
          test -r "$staging/verify-linkage.sh"
          test -r "$staging/qualify-ntpq.py"
          ;;
      esac
    done
    [ "$TEST_FAIL_QUALIFICATION" = false ] ;;
  *) exit 1 ;;
esac
`
			if err := os.WriteFile(mock, []byte(source), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", temp+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("TEST_DOCKER_LOG", log)
			t.Setenv("TEST_FAIL_QUALIFICATION", fmt.Sprint(failure))
			a := New(repositoryRoot(t), nil, io.Discard, io.Discard)
			err := a.Run(context.Background(), []string{"qualify-admin-diagnostics", diagnosticsRevision, "emisar/admin-diagnostics:test"})
			if (err != nil) != failure {
				t.Fatalf("qualification result: %v", err)
			}
			data, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			calls := strings.Split(strings.TrimSpace(string(data)), "\n")
			if len(calls) != 5 || calls[4] != "rm never-started-container" {
				t.Fatalf("unexpected lifecycle: %s", data)
			}
			for _, flag := range []string{"--network none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", "/run:rw,exec,nosuid,nodev,size=256m", ",dst=/qualification,readonly"} {
				if !strings.Contains(calls[3], flag) {
					t.Errorf("qualification lost isolation: %s", flag)
				}
			}
			_, staging, ok := strings.Cut(calls[2], "never-started-container:/bundle ")
			if !ok {
				t.Fatalf("missing extraction call: %s", calls[2])
			}
			if _, err := os.Stat(filepath.Dir(staging)); !os.IsNotExist(err) {
				t.Fatalf("qualification staging survived cleanup: %v", err)
			}
		})
	}
}

func TestAdminInventoryIAMIsNarrow(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/iam.tf"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if strings.Contains(text, `resource "google_project_iam_member" "vm_storage_policy_reader"`) {
		t.Fatal("bucket IAM policies readable project-wide")
	}
	for _, needle := range []string{`resource "google_storage_bucket_iam_member" "vm_storage_policy_reader"`, `toset([google_storage_bucket.pack_registry.name, google_storage_bucket.mta_sts.name])`, `permissions = ["storage.buckets.getIamPolicy"]`, `permissions = ["logging.logs.list"]`, `permissions = ["storage.buckets.list"]`} {
		if !strings.Contains(text, needle) {
			t.Errorf("IAM boundary missing %s", needle)
		}
	}
}

func TestDiagnosticsInstallIsAtomicBoundedAndUsesCachedDigest(t *testing.T) {
	root := repositoryRoot(t)
	mvBinary, err := exec.LookPath("mv")
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS == "darwin" {
		mvBinary, err = exec.LookPath("gmv")
		if err != nil {
			t.Skip("GNU mv is required to exercise the COS atomic rename on macOS")
		}
	}
	temp := t.TempDir()
	runtimeDir, mock := filepath.Join(temp, "runtime"), filepath.Join(temp, "mock")
	if err := os.Mkdir(mock, 0o700); err != nil {
		t.Fatal(err)
	}
	write := func(name, source string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(mock, name), []byte(source), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write("id", "#!/bin/sh\nprintf '0\\n'\n")
	write("uname", "#!/bin/sh\nprintf 'x86_64\\n'\n")
	write("chown", "#!/bin/sh\nexit 0\n")
	write("mv", "#!/bin/sh\nexec '"+mvBinary+"' \"$@\"\n")
	write("install", "#!/bin/bash\nargs=()\nwhile [ $# -gt 0 ]; do case \"$1\" in -o|-g) shift 2 ;; *) args+=(\"$1\"); shift ;; esac; done\nexec /usr/bin/install \"${args[@]}\"\n")
	write("docker", `#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
case "$1" in
  image) [ "$TEST_CACHED" = true ] ;;
  pull) [ "$TEST_PULL_AVAILABLE" = true ] ;;
  inspect)
    case "$3" in
      *RepoDigests*) printf '%s\n' "$TEST_IMAGE" ;;
      *) printf 'linux|amd64|%s|`+diagnosticsRevision+`\n' "$TEST_PURPOSE" ;;
    esac ;;
  create) printf 'never-started-container\n' ;;
  cp) [ "$TEST_CP_OK" = true ]; cp -a "$TEST_BUNDLE/." "${@: -1}" ;;
  rm) exit 0 ;;
  *) echo 'unexpected Docker execution' >&2; exit 1 ;;
esac
`)
	source, err := os.ReadFile(filepath.Join(root, "infra/runtime/admin-runner/install-diagnostics.sh"))
	if err != nil {
		t.Fatal(err)
	}
	script := strings.ReplaceAll(string(source), "/run/emisar-admin-runner", runtimeDir)
	script = strings.ReplaceAll(script, "/var/lib/emisar-admin-runner/verify-diagnostics.sh", filepath.Join(root, "infra/runtime/admin-runner/verify-diagnostics.sh"))
	installer := filepath.Join(temp, "install.sh")
	if err := os.WriteFile(installer, []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	bundle := diagnosticsFixture(t)
	if err := os.Chmod(filepath.Join(bundle, "libexec/ping"), 0o755|os.ModeSetuid|os.ModeSetgid); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(temp, "docker.log")
	image := "ghcr.io/andrewdryga/emisar@sha256:" + strings.Repeat("b", 64)
	t.Setenv("PATH", mock+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TEST_IMAGE", image)
	t.Setenv("TEST_BUNDLE", bundle)
	t.Setenv("TEST_DOCKER_LOG", log)
	t.Setenv("TEST_CACHED", "true")
	t.Setenv("TEST_PULL_AVAILABLE", "false")
	t.Setenv("TEST_CP_OK", "true")
	t.Setenv("TEST_PURPOSE", "admin-diagnostics")
	run := func() error {
		t.Helper()
		output, err := exec.Command("bash", installer, image).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%w: %s", err, output)
		}
		return nil
	}
	for n := 0; n < 4; n++ {
		if err := run(); err != nil {
			t.Fatal(err)
		}
	}
	generations, err := filepath.Glob(filepath.Join(runtimeDir, "diagnostics.*"))
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, generation := range generations {
		info, err := os.Lstat(generation)
		if err != nil {
			t.Fatal(err)
		}
		if info.IsDir() {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("repeated installs retain %d generations, want active + one prior", count)
	}
	active, err := os.Readlink(filepath.Join(runtimeDir, "diagnostics"))
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(runtimeDir, "diagnostics/libexec/ping"))
	if err != nil || info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
		t.Fatalf("installed privilege bits survived: %v %v", info, err)
	}
	assertPreserved := func() {
		t.Helper()
		got, err := os.Readlink(filepath.Join(runtimeDir, "diagnostics"))
		if err != nil || got != active {
			t.Fatalf("failed install replaced active generation: %s %v", got, err)
		}
	}
	for _, failure := range []string{"cp", "hash", "helper", "purpose", "registry"} {
		t.Run(failure, func(t *testing.T) {
			fixture := diagnosticsFixture(t)
			t.Setenv("TEST_BUNDLE", fixture)
			switch failure {
			case "cp":
				t.Setenv("TEST_CP_OK", "false")
			case "hash":
				if err := os.WriteFile(filepath.Join(fixture, "libexec/sar"), []byte("corrupt"), 0o700); err != nil {
					t.Fatal(err)
				}
			case "helper":
				if err := os.WriteFile(filepath.Join(fixture, "run-tool"), []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
					t.Fatal(err)
				}
				sealDiagnosticsFixture(t, fixture)
			case "purpose":
				t.Setenv("TEST_PURPOSE", "portal")
			case "registry":
				t.Setenv("TEST_CACHED", "false")
			}
			if err := run(); err == nil {
				t.Fatal("invalid install succeeded")
			}
			assertPreserved()
		})
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if strings.Contains(text, "run ") || strings.Contains(text, "--mount") || strings.Contains(text, "--volume") || !strings.Contains(text, "rm never-started-container") {
		t.Fatalf("extraction was executed/mounted or not cleaned up: %s", text)
	}
	if strings.Count(text, "pull ") != 1 {
		t.Fatalf("cached restarts contacted registry: %s", text)
	}
}

func TestInstalledManifestPreflightFailsClosed(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/start.sh"))
	if err != nil {
		t.Fatal(err)
	}
	start := strings.Index(string(source), "installed_packs=$(")
	if start < 0 {
		t.Fatal("installed-manifest preflight missing")
	}
	end := strings.Index(string(source)[start:], "docker compose version") + start
	if start < 0 || end < start {
		t.Fatal("installed-manifest preflight missing")
	}
	block := string(source)[start:end]
	for _, tc := range []struct {
		name, output string
		exit         int
		ok           bool
	}{
		{"complete installed manifests", `[{"requires":{"binaries":["bash","jq"]}}]`, 0, true},
		{"failed producer with valid partial output", `[{"requires":{"binaries":["bash"]}}]`, 1, false},
		{"empty installed set", `[]`, 0, false},
		{"malformed installed set", `{`, 0, false},
		{"missing declared binary", `[{"requires":{"binaries":["missing-emisar-fixture-binary"]}}]`, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mock := filepath.Join(t.TempDir(), "runner")
			if err := os.WriteFile(mock, []byte(fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' '%s'\nexit %d\n", tc.output, tc.exit)), 0o700); err != nil {
				t.Fatal(err)
			}
			command := exec.Command("bash", "-c", "set -euo pipefail\nrunner=$1\n"+block, "preflight", mock)
			output, err := command.CombinedOutput()
			if (err == nil) != tc.ok {
				t.Fatalf("unexpected preflight result: %v\n%s", err, output)
			}
		})
	}
}
