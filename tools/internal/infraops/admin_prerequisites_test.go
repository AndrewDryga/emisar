package infraops

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

func TestAdminInstalledPackContracts(t *testing.T) {
	root := repositoryRoot(t)
	pins, err := adminRunnerPins(filepath.Join(root, "infra/runtime/admin-runner/pack-pins.txt"))
	if err != nil {
		t.Fatal(err)
	}
	bundle, err := os.ReadFile(filepath.Join(root, "infra/runtime/admin-runner/diagnostics/commands.txt"))
	if err != nil {
		t.Fatal(err)
	}
	// Native COS commands and fixed bridges must not be replaced by distribution
	// versions that might inspect a different service manager or container engine.
	available := map[string]bool{}
	for _, cmd := range strings.Fields(string(bundle) + " cloud-init docker journalctl shutdown systemctl systemd-analyze systemd-cgls systemd-cgtop timedatectl gcloud elixir erl epmd") {
		available[cmd] = true
	}
	startup, err := os.ReadFile(filepath.Join(root, "infra/runtime/admin-runner/start.sh"))
	if err != nil {
		t.Fatal(err)
	}
	declared := regexp.MustCompile(`declared_dependencies='([^']+)'`).FindSubmatch(startup)
	if len(declared) != 2 {
		t.Fatal("missing startup dependency check")
	}
	checked := map[string]bool{"gcloud": true, "elixir": true, "erl": true, "epmd": true}
	for _, cmd := range strings.Fields(string(declared[1])) {
		checked[cmd] = true
	}
	binary := adminRunnerBinary(t, root)
	temp := t.TempDir()
	packDir := filepath.Join(temp, "packs")
	if err := os.MkdirAll(packDir, 0700); err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{}
	for _, pin := range append(pins, "emisar-admin=private|") {
		id := strings.SplitN(pin, "=", 2)[0]
		source := filepath.Join(root, "packs", id)
		if id == "emisar-admin" {
			source = filepath.Join(root, "infra/packs/emisar-admin")
		}
		body, err := os.ReadFile(filepath.Join(source, "pack.yaml"))
		if err != nil {
			t.Fatal(err)
		}
		var manifest struct {
			Requires struct {
				Binaries []string `yaml:"binaries"`
			} `yaml:"requires"`
			Actions []string `yaml:"actions"`
		}
		if err := yaml.Unmarshal(body, &manifest); err != nil {
			t.Fatal(err)
		}
		for _, cmd := range manifest.Requires.Binaries {
			if !available[cmd] || !checked[cmd] {
				t.Errorf("%s dependency %s not provisioned and checked", id, cmd)
			}
		}
		hash := strings.SplitN(pin, "|", 2)[1]
		output, err := exec.Command(binary, "pack", "validate", source).CombinedOutput()
		if err != nil || (hash != "" && !strings.Contains(string(output), "hash: "+hash)) {
			t.Fatalf("%s source differs from installed pin: %v %s", id, err, output)
		}
		if err := os.CopyFS(filepath.Join(packDir, id), os.DirFS(source)); err != nil {
			t.Fatal(err)
		}
		for _, path := range manifest.Actions {
			body, err := os.ReadFile(filepath.Join(source, path))
			if err != nil {
				t.Fatal(err)
			}
			var action struct {
				ID string `yaml:"id"`
			}
			if err := yaml.Unmarshal(body, &action); err != nil {
				t.Fatal(err)
			}
			expected[action.ID] = id
		}
	}
	config, err := os.ReadFile(filepath.Join(root, "infra/runtime/admin-runner/config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	cfg := strings.ReplaceAll(string(config), "${domain}", "example.test")
	cfg = strings.ReplaceAll(cfg, "/var/lib/emisar-admin-runner/packs", packDir)
	cfg = strings.ReplaceAll(cfg, "/var/lib/emisar-admin-runner/data", filepath.Join(temp, "data"))
	cfg = strings.ReplaceAll(cfg, "/var/lib/emisar-admin-runner/log/events.jsonl", filepath.Join(temp, "events.jsonl"))
	cfgPath := filepath.Join(temp, "config.yaml")
	if err := os.WriteFile(cfgPath, []byte(cfg), 0600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(binary, "--config", cfgPath, "state").CombinedOutput()
	if err != nil {
		t.Fatalf("state: %v %s", err, output)
	}
	if len(output) > 2<<20 {
		t.Fatal("installed pack advertisement exceeds the wire frame limit")
	}
	var state struct {
		Actions []struct {
			ID                    string `json:"id"`
			LocalAdmissionAllowed bool   `json:"local_admission_allowed"`
		} `json:"actions"`
	}
	if err := json.Unmarshal(output, &state); err != nil {
		t.Fatalf("state decode: %v %s", err, output)
	}
	denied := map[string]bool{"debugging.pid_environ": true, "docker.inspect": true, "tfc.apply_run": true, "tfc.discard_run": true, "tfc.cancel_run": true, "tfc.retry_run": true, "tfc.force_unlock_workspace": true}
	for _, action := range state.Actions {
		if _, ok := expected[action.ID]; !ok {
			t.Errorf("unexpected descriptor %s", action.ID)
		}
		delete(expected, action.ID)
		if action.LocalAdmissionAllowed == denied[action.ID] {
			t.Errorf("wrong admission for %s", action.ID)
		}
	}
	if len(expected) > 0 {
		t.Fatalf("installed actions missing from complete descriptor set: %v", expected)
	}
}

func TestAdminStorageReadBoundaries(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/iam.tf"))
	if err != nil {
		t.Fatal(err)
	}
	iam := string(data)
	block := func(kind, name string) string {
		return regexp.MustCompile(`(?ms)^resource "` + kind + `" "` + name + `" \{.*?^\}`).FindString(iam)
	}
	logs := block("google_project_iam_custom_role", "vm_log_inventory")
	if !strings.Contains(logs, `permissions = ["logging.logs.list"]`) {
		t.Fatal("log-name inventory must not grant payload reads")
	}
	inventory := block("google_project_iam_custom_role", "vm_storage_inventory")
	if !strings.Contains(inventory, `permissions = ["storage.buckets.list"]`) {
		t.Fatal("project inventory must grant only bucket listing")
	}
	if block("google_project_iam_member", "vm_storage_policy_reader") != "" {
		t.Fatal("bucket policy reads must not become project-wide")
	}
	policy := block("google_storage_bucket_iam_member", "vm_storage_policy_reader")
	for _, name := range []string{"google_storage_bucket.pack_registry.name", "google_storage_bucket.mta_sts.name", "google_project_iam_custom_role.vm_storage_policy_reader.name"} {
		if !strings.Contains(policy, name) {
			t.Errorf("missing bounded policy grant %s", name)
		}
	}
	objects := block("google_storage_bucket_iam_member", "vm_bucket_read")
	if !strings.Contains(objects, "google_storage_bucket.pack_registry.name, google_storage_bucket.mta_sts.name") {
		t.Fatal("object reads lost exact bucket boundary")
	}
	for _, role := range []string{"roles/storage.admin", "roles/storage.objectAdmin"} {
		if strings.Contains(iam, role) {
			t.Fatalf("unexpected storage mutation grant %s", role)
		}
	}
}

func TestAdminDiagnosticsWrapper(t *testing.T) {
	root := repositoryRoot(t)
	wrapper, err := os.ReadFile(filepath.Join(root, "infra/runtime/admin-runner/diagnostics/run-tool"))
	if err != nil {
		t.Fatal(err)
	}
	temp := t.TempDir()
	for _, dir := range []string{"bin", "lib", "libexec"} {
		if err := os.Mkdir(filepath.Join(temp, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(temp, "run-tool"), wrapper, 0700); err != nil {
		t.Fatal(err)
	}
	loader := `#!/bin/sh
printf '%s\n' "$@"
printf 'PYTHONHOME=%s\nPYTHONPATH=%s\nLD_PRELOAD=%s\n' "${PYTHONHOME-}" "${PYTHONPATH-}" "${LD_PRELOAD-}"
`
	if err := os.WriteFile(filepath.Join(temp, "lib/loader"), []byte(loader), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"iostat", "sadc", "ntpq", "evil"} {
		path := filepath.Join(temp, "bin", name)
		if err := os.Symlink("../run-tool", path); err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command(path, "literal; echo injected", "--argument").CombinedOutput()
		if name == "evil" {
			if err == nil || !strings.Contains(string(out), "unsupported") {
				t.Fatalf("unexpected executable accepted: %v %s", err, out)
			}
			continue
		}
		if err != nil {
			t.Fatalf("wrapper %s: %v %s", name, err, out)
		}
		if !strings.Contains(string(out), "literal; echo injected\n--argument") || !strings.Contains(string(out), filepath.Join(temp, "libexec")) {
			t.Fatalf("argv boundary lost: %s", out)
		}
		if name == "ntpq" && !strings.Contains(string(out), "PYTHONHOME="+temp+"/python") {
			t.Fatalf("Python closure not selected: %s", out)
		}
	}
}

func TestAdminDiagnosticsInstall(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(repositoryRoot(t), "infra/runtime/admin-runner/install-diagnostics.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, command    string
		badImage, broken bool
	}{
		{name: "complete bundle", command: "iostat"},
		{name: "unexpected executable", command: "arbitrary-shell"},
		{name: "mutable image", command: "iostat", badImage: true},
		{name: "broken loader", command: "iostat", broken: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			temp := t.TempDir()
			runtime := filepath.Join(temp, "runtime")
			fixture := filepath.Join(temp, "fixture")
			mock := filepath.Join(temp, "mock")
			for _, dir := range []string{runtime, filepath.Join(runtime, "diagnostics"), mock, filepath.Join(fixture, "bin"), filepath.Join(fixture, "lib"), filepath.Join(fixture, "libexec"), filepath.Join(fixture, "cli-plugins")} {
				if err := os.MkdirAll(dir, 0700); err != nil {
					t.Fatal(err)
				}
			}
			marker := filepath.Join(runtime, "diagnostics", "previous")
			if err := os.WriteFile(marker, []byte("old"), 0600); err != nil {
				t.Fatal(err)
			}
			success := []byte("#!/bin/sh\nexit 0\n")
			for _, name := range []string{"run-tool", "lib/loader", "cli-plugins/docker-compose", "libexec/" + tc.command} {
				if err := os.WriteFile(filepath.Join(fixture, name), success, 0777); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(fixture, "commands.txt"), []byte(tc.command+"\n"), 0644); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{tc.command, "sadc", "ntpq"} {
				if err := os.Symlink("../run-tool", filepath.Join(fixture, "bin", name)); err != nil {
					t.Fatal(err)
				}
			}
			if tc.broken {
				if err := os.WriteFile(filepath.Join(fixture, "run-tool"), []byte("#!/bin/sh\nexit 1\n"), 0700); err != nil {
					t.Fatal(err)
				}
			}
			docker := `#!/bin/sh
set -eu
printf '%s\n' "$1" >> "$DOCKER_CALLS"
case "$1" in
 image) exit "${CACHE_MISS:-0}" ;;
 pull|rm) ;;
 create) printf '%s\n' fixture-container ;;
 cp) cp -a "$BUNDLE_FIXTURE/." "$3" ;;
 *) echo unexpected >&2; exit 1 ;;
esac
`
			if err := os.WriteFile(filepath.Join(mock, "docker"), []byte(docker), 0700); err != nil {
				t.Fatal(err)
			}
			script := filepath.Join(temp, "install.sh")
			if err := os.WriteFile(script, []byte(strings.Replace(string(source), "root=/run/emisar-admin-runner", "root="+runtime, 1)), 0700); err != nil {
				t.Fatal(err)
			}
			image := "example.test/diagnostics:v1@sha256:" + strings.Repeat("a", 64)
			if tc.badImage {
				image = "example.test/diagnostics:latest"
			}
			cmd := exec.Command("bash", script, image)
			cmd.Env = append(os.Environ(), "PATH="+mock+":"+os.Getenv("PATH"), "BUNDLE_FIXTURE="+fixture, "DOCKER_CALLS="+filepath.Join(temp, "calls"))
			out, err := cmd.CombinedOutput()
			bad := tc.badImage || tc.broken || tc.command == "arbitrary-shell"
			if bad {
				if err == nil {
					t.Fatalf("invalid bundle accepted: %s", out)
				}
				if _, err := os.Stat(marker); err != nil {
					t.Fatal("failed install removed previous bundle")
				}
			} else {
				if err != nil {
					t.Fatalf("install: %v %s", err, out)
				}
				info, err := os.Stat(filepath.Join(runtime, "diagnostics/run-tool"))
				if err != nil {
					t.Fatal(err)
				}
				if info.Mode().Perm()&0022 != 0 {
					t.Fatal("installed executable is group/world writable")
				}
				config, err := os.ReadFile(filepath.Join(runtime, "docker/config.json"))
				if err != nil || !strings.Contains(string(config), runtime+"/diagnostics/cli-plugins") {
					t.Fatalf("plugin config: %v %s", err, config)
				}
			}
			calls, _ := os.ReadFile(filepath.Join(temp, "calls"))
			if strings.Contains(string(calls), "pull\n") {
				t.Fatal("cached immutable image still requires registry access")
			}
			if strings.Contains(string(calls), "run\n") || strings.Contains(string(calls), "start\n") {
				t.Fatal("diagnostics image was executed")
			}
			if !tc.badImage && !strings.HasSuffix(string(calls), "rm\n") {
				t.Fatalf("temporary container not removed: %s", calls)
			}
		})
	}
}
