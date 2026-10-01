package infraops

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// Pins may intentionally lag the catalog, but must retain an exact published
// identity. The network publication check belongs to the version review.
func TestAdminRunnerPinsMatchCatalog(t *testing.T) {
	root := repositoryRoot(t)
	pins, err := adminRunnerPins(filepath.Join(root, "infra/runtime/admin-runner/pack-pins.txt"))
	if err != nil {
		t.Fatal(err)
	}
	type version struct {
		Version string `json:"version"`
		Hash    string `json:"content_hash"`
	}
	var catalog struct {
		Packs []struct {
			version
			ID       string    `json:"id"`
			Previous []version `json:"previous_versions"`
		} `json:"packs"`
	}
	body, err := os.ReadFile(filepath.Join(root, "portal/apps/emisar/priv/packs/catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &catalog); err != nil {
		t.Fatal(err)
	}
	published := map[string]bool{}
	for _, pack := range catalog.Packs {
		for _, v := range append(pack.Previous, pack.version) {
			published[pack.ID+"="+v.Version+"|"+v.Hash] = true
		}
	}
	seen := map[string]bool{}
	for _, pin := range pins {
		id := strings.SplitN(pin, "=", 2)[0]
		if seen[id] {
			t.Errorf("duplicate pack pin: %s", id)
		}
		seen[id] = true
		if !published[pin] {
			t.Errorf("pin is absent from bundled publication history: %s", pin)
		}
	}
}

// Exercise the shipped action's argv and script against a view-only Logging
// fixture. Project reads must fail, not fall back to broader credentials.
func TestAdminContainerLogView(t *testing.T) {
	root := repositoryRoot(t)
	pack := filepath.Join(root, "packs/gcp-monitoring")
	var action struct {
		Args []struct {
			Name    string `yaml:"name"`
			Default any    `yaml:"default"`
		} `yaml:"args"`
		Execution struct {
			Script struct {
				Path string `yaml:"path"`
			} `yaml:"script"`
			Argv []string `yaml:"argv"`
		} `yaml:"execution"`
	}
	data, err := os.ReadFile(filepath.Join(pack, "actions/log_entries.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(data, &action); err != nil {
		t.Fatal(err)
	}
	defaults := map[string]string{}
	for _, arg := range action.Args {
		if arg.Default != nil {
			defaults[arg.Name] = fmt.Sprint(arg.Default)
		}
	}
	if _, ok := defaults["view_id"]; !ok {
		t.Fatal("log action cannot address the granted view")
	}
	// Keep the regression tied to the deployed pin, not only newer source files.
	catalogData, err := os.ReadFile(filepath.Join(root, "portal/apps/emisar/priv/packs/catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	var catalog struct {
		Packs []struct {
			ID, Version string
			Hash        string `json:"content_hash"`
		}
	}
	if err := json.Unmarshal(catalogData, &catalog); err != nil {
		t.Fatal(err)
	}
	pins, err := adminRunnerPins(filepath.Join(root, "infra/runtime/admin-runner/pack-pins.txt"))
	if err != nil {
		t.Fatal(err)
	}
	monitoringHash := ""
	for _, p := range catalog.Packs {
		if p.ID == "gcp-monitoring" {
			monitoringHash = p.Hash
			want := p.ID + "=" + p.Version + "|" + p.Hash
			found := false
			for _, pin := range pins {
				found = found || pin == want
			}
			if !found {
				t.Fatal("diagnostic test requires the infrastructure monitoring pin to match the tested catalog version")
			}
		}
	}
	if monitoringHash == "" {
		t.Fatal("catalog is missing gcp-monitoring")
	}
	binary := adminRunnerBinary(t, root)
	validation, err := exec.Command(binary, "pack", "validate", pack).CombinedOutput()
	if err != nil || !strings.Contains(string(validation), "hash: "+monitoringHash) {
		t.Fatalf("tested pack bytes differ from the infrastructure pin: %v\n%s", err, validation)
	}
	logging, err := os.ReadFile(filepath.Join(root, "infra/logging.tf"))
	if err != nil {
		t.Fatal(err)
	}
	view := regexp.MustCompile(`(?ms)^resource "google_logging_log_view" "vm_containers" \{.*?^\}`).Find(logging)
	for _, part := range []string{`name        = "emisar-vm-containers"`, `resource.type=\"gce_instance\" AND LOG_ID(\"cos_containers\")`} {
		if !strings.Contains(string(view), part) {
			t.Fatalf("container view boundary changed: %s", part)
		}
	}
	iam, err := os.ReadFile(filepath.Join(root, "infra/iam.tf"))
	if err != nil {
		t.Fatal(err)
	}
	grant := regexp.MustCompile(`(?ms)^resource "google_logging_log_view_iam_member" "vm_container_logs" \{.*?^\}`).Find(iam)
	for _, part := range []string{`role     = "roles/logging.viewAccessor"`, `name     = google_logging_log_view.vm_containers.name`, `member   = "serviceAccount:${google_service_account.vm.email}"`} {
		if !strings.Contains(string(grant), part) {
			t.Fatalf("view-only grant changed: %s", part)
		}
	}
	for _, role := range []string{"roles/logging.viewer", "roles/logging.privateLogViewer"} {
		if strings.Contains(string(iam), role) {
			t.Fatalf("unexpected broad log role: %s", role)
		}
	}
	for _, tc := range []struct {
		name, view string
		denied     bool
	}{
		{"granted view", "emisar-vm-containers", false},
		{"project-wide read", "", true},
		{"other view", "other-workload", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, script := range map[string]string{
				"gcloud": "#!/bin/sh\nprintf '%s\\n' fixture-access-token\n",
				"curl": `#!/bin/sh
set -eu
cat >/dev/null
printf 'request\n' >> "$REQUEST_COUNT"
while [ "$#" -gt 0 ]; do
 if [ "$1" = --data-binary ]; then shift; cp "${1#@}" "$REQUEST_BODY"; fi
 shift
done
if ! jq -e '.resourceNames == ["projects/example-prod/locations/global/buckets/_Default/views/emisar-vm-containers"]' "$REQUEST_BODY" >/dev/null; then
 printf '%s\n' '{"error":{"message":"Permission denied for all log views"}}'
 exit 22
fi
printf '%s\n' '{"entries":[{"jsonPayload":{"message":"fixture-access-token diagnostic","job":"sweep"}}],"nextPageToken":"next-page"}'
`,
			} {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			values := map[string]string{}
			for k, v := range defaults {
				values[k] = v
			}
			values["project"], values["view_id"] = "example-prod", tc.view
			values["resource_type"], values["log_id"] = "gce_instance", "cos_containers"
			values["json_message"], values["page_cursor"] = "recurrent_job.failed", "prior-page"
			argv := []string{filepath.Join(pack, action.Execution.Script.Path)}
			for _, a := range action.Execution.Argv {
				for k, v := range values {
					a = strings.ReplaceAll(a, "{{ args."+k+" }}", v)
				}
				if strings.Contains(a, "{{") {
					t.Fatalf("unresolved argv: %s", a)
				}
				argv = append(argv, a)
			}
			cmd := exec.Command("/bin/sh", argv...)
			cmd.Env = append(os.Environ(), "PATH="+dir+":"+os.Getenv("PATH"), "REQUEST_BODY="+filepath.Join(dir, "request.json"), "REQUEST_COUNT="+filepath.Join(dir, "count"))
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			err := cmd.Run()
			if tc.denied {
				if err == nil || !strings.Contains(stderr.String(), "Permission denied") {
					t.Fatalf("denial lost: %v %s", err, stderr.String())
				}
				if stdout.Len() != 0 {
					t.Fatalf("denial returned successful output: %s", stdout.String())
				}
			} else {
				if err != nil {
					t.Fatalf("scoped read failed: %v %s", err, stderr.String())
				}
				if strings.Contains(stdout.String(), "fixture-access-token") || !strings.Contains(stdout.String(), "[REDACTED] diagnostic") {
					t.Fatalf("token redaction lost: %s", stdout.String())
				}
				if !strings.Contains(stdout.String(), `"next_page_cursor":"next-page"`) {
					t.Fatalf("pagination lost: %s", stdout.String())
				}
			}
			count, err := os.ReadFile(filepath.Join(dir, "count"))
			if err != nil || string(count) != "request\n" {
				t.Fatalf("unexpected retry or fallback: %q %v", count, err)
			}
			request, err := os.ReadFile(filepath.Join(dir, "request.json"))
			if err != nil {
				t.Fatal(err)
			}
			var body struct {
				Filter    string
				PageToken string
				PageSize  int
			}
			if err := json.Unmarshal(request, &body); err != nil {
				t.Fatal(err)
			}
			for _, filter := range []string{`resource.type = "gce_instance"`, `logName = "projects/example-prod/logs/cos_containers"`, `jsonPayload.message = "recurrent_job.failed"`} {
				if !strings.Contains(body.Filter, filter) {
					t.Errorf("missing filter %s in %s", filter, body.Filter)
				}
			}
			if body.PageToken != "prior-page" || body.PageSize != 5 {
				t.Fatalf("unbounded or wrong page: %s", request)
			}
		})
	}
}
