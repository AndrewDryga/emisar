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
	data, err := os.ReadFile(filepath.Join(root, "portal/apps/emisar/priv/packs/catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &catalog); err != nil {
		t.Fatal(err)
	}
	published := map[string]bool{}
	for _, pack := range catalog.Packs {
		for _, v := range append(pack.Previous, pack.version) {
			published[pack.ID+"="+v.Version+"|"+v.Hash] = true
		}
	}
	// Pins may intentionally lag; retained exact identities are valid too.
	for _, pin := range pins {
		if !published[pin] {
			t.Errorf("pin is absent from bundled publication history: %s", pin)
		}
	}
}

func TestAdminRunnerPinsRejectDuplicateIDs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pins")
	if err := os.WriteFile(path, []byte("example=0.1.0|sha256:first\nexample=0.2.0|sha256:second\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := adminRunnerPins(path); err == nil || !strings.Contains(err.Error(), "duplicate pack pin") {
		t.Fatalf("duplicate pin was not rejected: %v", err)
	}
}

// Provider behavior (including other-view/project refusal and continuations)
// is exercised by gcp-monitoring's real-client behavior plan. This regression
// binds that contract to the exact deployed pack, view and resource-level IAM.
func TestAdminContainerLogViewBoundary(t *testing.T) {
	root := repositoryRoot(t)
	packDir := filepath.Join(root, "packs/gcp-monitoring")
	binary := adminRunnerBinary(t, root)
	output, err := exec.Command(binary, "pack", "validate", packDir).CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	pins, err := adminRunnerPins(filepath.Join(root, "infra/runtime/admin-runner/pack-pins.txt"))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, pin := range pins {
		if strings.HasPrefix(pin, "gcp-monitoring=") {
			_, hash, _ := strings.Cut(pin, "|")
			found = strings.Contains(string(output), "hash: "+hash)
		}
	}
	if !found {
		t.Fatal("deployed monitoring pin does not match the exercised source contract")
	}
	data, err := os.ReadFile(filepath.Join(packDir, "actions/log_entries.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var action struct {
		Args []struct {
			Name       string `yaml:"name"`
			Validation struct {
				MaxLength int `yaml:"max_length"`
			} `yaml:"validation"`
		} `yaml:"args"`
	}
	if err := yaml.Unmarshal(data, &action); err != nil {
		t.Fatal(err)
	}
	viewArg := false
	for _, arg := range action.Args {
		viewArg = viewArg || (arg.Name == "view_id" && arg.Validation.MaxLength > 0)
	}
	if !viewArg {
		t.Fatal("deployed log action cannot address a bounded view")
	}
	for _, tc := range []struct {
		file, resource string
		needles        []string
	}{
		{"logging.tf", `google_logging_log_view" "vm_containers`, []string{
			`name        = "emisar-vm-containers"`,
			`resource.type=\"gce_instance\" AND LOG_ID(\"cos_containers\")`,
		}},
		{"iam.tf", `google_logging_log_view_iam_member" "vm_container_logs`, []string{
			`name     = google_logging_log_view.vm_containers.name`,
			`role     = "roles/logging.viewAccessor"`,
			`member   = "serviceAccount:${google_service_account.vm.email}"`,
		}},
	} {
		data, err := os.ReadFile(filepath.Join(root, "infra", tc.file))
		if err != nil {
			t.Fatal(err)
		}
		block := regexp.MustCompile(`(?ms)^resource "` + regexp.QuoteMeta(tc.resource) + `" \{.*?^\}`).Find(data)
		for _, needle := range tc.needles {
			if !strings.Contains(string(block), needle) {
				t.Errorf("%s view boundary is missing %q", tc.file, needle)
			}
		}
		if tc.file == "iam.tf" {
			for _, broad := range []string{"roles/logging.viewer", "roles/logging.privateLogViewer"} {
				if strings.Contains(string(data), broad) {
					t.Errorf("unexpected project-wide logging read grant: %s", broad)
				}
			}
		}
	}
}
