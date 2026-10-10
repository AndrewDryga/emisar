package infraops

import (
	"crypto/sha256"
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
// binds that contract to the configured pack, view and resource-level IAM.
// An unrelated Monitoring change may precede publication and the pin update;
// it must not force the configured runner onto an unpublished pack.
func TestAdminContainerLogViewBoundary(t *testing.T) {
	root := repositoryRoot(t)
	packDir := filepath.Join(root, "packs/gcp-monitoring")
	binary := adminRunnerBinary(t, root)
	output, err := exec.Command(binary, "pack", "validate", packDir).CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(filepath.Join(packDir, "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var current struct {
		ID      string `yaml:"id"`
		Version string `yaml:"version"`
	}
	if err := yaml.Unmarshal(manifest, &current); err != nil {
		t.Fatal(err)
	}
	hash := regexp.MustCompile(`(?m)^hash: (sha256:[0-9a-f]{64})$`).FindSubmatch(output)
	if len(hash) != 2 {
		t.Fatalf("pack validation omitted an exact content hash: %s", output)
	}
	currentPin := current.ID + "=" + current.Version + "|" + string(hash[1])
	pins, err := adminRunnerPins(filepath.Join(root, "infra/runtime/admin-runner/pack-pins.txt"))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, pin := range pins {
		if strings.HasPrefix(pin, "gcp-monitoring=") {
			if err := adminLoggingPinMatches(currentPin, pin, packDir, qualifiedLoggingFiles); err != nil {
				t.Fatal(err)
			}
			found = true
		}
	}
	if !found {
		t.Fatal("configured monitoring pin is missing")
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
		t.Fatal("configured log action cannot address a bounded view")
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

// Qualified from the registry's immutable 0.3.11 artifact, independently loaded
// and validated at its exact pack hash. These are NOT regenerated from HEAD.
// Retaining that identity is safe for this regression only while BOTH Logging
// files remain byte-identical; any Logging change needs a qualified new pin.
const qualifiedLoggingPin = "gcp-monitoring=0.3.11|sha256:ba5d8317195c40d7d3cc8740d73cd20b8bc7060ae3580129fe8b00ec0293bef9"

var qualifiedLoggingFiles = map[string]string{
	"actions/log_entries.yaml": "687220bf98f2ffb4fbed75bed47eb263e77b7c978c5550cdcc9af06bd3f17b19",
	"scripts/logging_api.sh":   "2a279467db499f2aacde30da7fa59ae657a92dafb3c05e360b8c426da4504edd",
}

func adminLoggingPinMatches(currentPin, pin, packDir string, files map[string]string) error {
	if pin == currentPin {
		return nil
	}
	if pin != qualifiedLoggingPin {
		return fmt.Errorf("configured monitoring pin does not match the exercised Logging contract: %s", pin)
	}
	for path, expected := range files {
		data, err := os.ReadFile(filepath.Join(packDir, path))
		if err != nil {
			return fmt.Errorf("read retained Logging contract %s: %w", path, err)
		}
		if fmt.Sprintf("%x", sha256.Sum256(data)) != expected {
			return fmt.Errorf("retained monitoring pin no longer matches Logging source: %s", path)
		}
	}
	return nil
}

func TestAdminLoggingPinRequiresExactQualifiedContract(t *testing.T) {
	current := "gcp-monitoring=0.3.12|sha256:" + strings.Repeat("1", 64)
	// Test the equivalence check with independent fixture bytes, so advancing
	// the actual pin to changed Logging source does not invalidate this unit
	// test's retained-positive row. The real boundary test uses only the
	// authenticated published-file digests above.
	fixtures := map[string][]byte{
		"actions/log_entries.yaml": []byte("qualified Logging action fixture\n"),
		"scripts/logging_api.sh":   []byte("qualified Logging script fixture\n"),
	}
	expected := map[string]string{}
	for path, data := range fixtures {
		expected[path] = fmt.Sprintf("%x", sha256.Sum256(data))
	}
	for _, tc := range []struct {
		name, pin, changed, missing string
		wantSuccess                 bool
	}{
		{name: "current identity", pin: current, wantSuccess: true},
		{name: "qualified retained identity", pin: qualifiedLoggingPin, wantSuccess: true},
		{name: "action changed", pin: qualifiedLoggingPin, changed: "actions/log_entries.yaml"},
		{name: "script changed", pin: qualifiedLoggingPin, changed: "scripts/logging_api.sh"},
		{name: "action missing", pin: qualifiedLoggingPin, missing: "actions/log_entries.yaml"},
		{name: "script missing", pin: qualifiedLoggingPin, missing: "scripts/logging_api.sh"},
		{name: "wrong retained version", pin: strings.Replace(qualifiedLoggingPin, "0.3.11", "0.3.10", 1)},
		{name: "wrong retained hash", pin: qualifiedLoggingPin + "0"},
		{name: "unqualified retained identity", pin: "gcp-monitoring=0.3.10|sha256:02240406a1fe11a6f0c3210eab444090643fa6f41134b8fb7c56c4af2f93cafa"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for path, fixture := range fixtures {
				if path == tc.missing {
					continue
				}
				data := append([]byte(nil), fixture...)
				if path == tc.changed {
					data = append(data, '\n')
				}
				if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, path)), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(dir, path), data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if err := adminLoggingPinMatches(current, tc.pin, dir, expected); (err == nil) != tc.wantSuccess {
				t.Fatalf("Logging pin equivalence: error=%v want success=%v", err, tc.wantSuccess)
			}
		})
	}
}
