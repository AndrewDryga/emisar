package ci

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validImageIdentity() imageIdentity {
	identity := imageIdentity{ID: "sha256:" + strings.Repeat("a", 64), OS: "linux", Architecture: "amd64"}
	identity.Config.Labels = map[string]string{"org.emisar.image-purpose": "portal", "org.opencontainers.image.revision": strings.Repeat("b", 40)}
	return identity
}

func TestImageIdentityRejectsSwappedPurposeAndWrongArchitecture(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*imageIdentity)
	}{
		{"wrong purpose", func(i *imageIdentity) { i.Config.Labels["org.emisar.image-purpose"] = "admin-diagnostics" }},
		{"wrong revision", func(i *imageIdentity) { i.Config.Labels["org.opencontainers.image.revision"] = strings.Repeat("c", 40) }},
		{"wrong architecture", func(i *imageIdentity) { i.Architecture = "arm64" }},
		{"wrong os", func(i *imageIdentity) { i.OS = "darwin" }},
		{"missing identity", func(i *imageIdentity) { i.ID = "" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			identity := validImageIdentity()
			tc.edit(&identity)
			if err := validateImageIdentity(identity, "portal", strings.Repeat("b", 40)); err == nil {
				t.Fatal("invalid image accepted")
			}
		})
	}
	identity := validImageIdentity()
	if err := validateImageIdentity(identity, "portal", strings.Repeat("b", 40)); err != nil {
		t.Fatal(err)
	}
	identity.Config.Labels["org.emisar.image-purpose"] = "admin-diagnostics"
	if err := validateImageIdentity(identity, "admin-diagnostics", strings.Repeat("b", 40)); err != nil {
		t.Fatal(err)
	}
}

func TestImageContractRejectsChangedArchiveSBOMAndImage(t *testing.T) {
	temp := t.TempDir()
	identity := validImageIdentity()
	data, err := json.Marshal(identity)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(temp, "docker"), []byte("#!/bin/sh\nprintf '%s\\n' \"$TEST_IMAGE_IDENTITY\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", temp+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TEST_IMAGE_IDENTITY", string(data))
	archive, sbom, contract := filepath.Join(temp, "image.tar.gz"), filepath.Join(temp, "sbom.json"), filepath.Join(temp, "contract.json")
	for _, path := range []string{archive, sbom} {
		if err := os.WriteFile(path, []byte("tested artifact"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	call := func(mode string) error {
		return ImageContract(context.Background(), temp, mode, "portal", strings.Repeat("b", 40), "portal:test", archive, sbom, contract)
	}
	if err := call("create"); err != nil {
		t.Fatal(err)
	}
	if err := call("verify"); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{archive, sbom} {
		if err := os.WriteFile(path, []byte("changed artifact"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := call("verify"); err == nil {
			t.Fatalf("modified %s accepted", path)
		}
		if err := os.WriteFile(path, []byte("tested artifact"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	identity.ID = "sha256:" + strings.Repeat("c", 64)
	data, _ = json.Marshal(identity)
	t.Setenv("TEST_IMAGE_IDENTITY", string(data))
	if err := call("verify"); err == nil {
		t.Fatal("different image config accepted")
	}
}

func TestDiagnosticsSelectionAndWorkflowContract(t *testing.T) {
	for _, path := range []string{"infra/runtime/admin-runner/diagnostics/run-tool", "infra/runtime/admin-runner/start.sh", "tools/internal/infraops/admin_diagnostics.go", "portal/docker/debian.sources", ".dockerignore"} {
		var selection Selection
		selection.include(path)
		if !selection.AdminDiagnostics {
			t.Errorf("%s skips native qualification", path)
		}
	}
	root := newGitRepo(t)
	writeFixture(t, root, "README.md", "base\n")
	writeFixture(t, root, "packs/mysql/test/cases.yaml", behaviorPlan("mysql", versionRow("9.7.1", "c", true)))
	commitAll(t, root, "base")
	base := gitText(t, root, "rev-parse", "HEAD")
	writeFixture(t, root, "README.md", "changed\n")
	commitAll(t, root, "docs")
	selection, err := Select(context.Background(), root, "push", base)
	if err != nil || !selection.AdminDiagnostics {
		t.Fatalf("main skipped qualification: %+v %v", selection, err)
	}
	output := filepath.Join(t.TempDir(), "output")
	if err := WriteSelection(context.Background(), root, "push", base, output, ""); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(output)
	if !strings.Contains(string(data), "admin_diagnostics=true\n") {
		t.Fatal("required job has no literal selection output")
	}
}

func TestDebianInventoryRetainsSourceIdentityAndBinNMU(t *testing.T) {
	for _, tc := range []struct {
		row, binary, source, epoch, upstream, release string
	}{
		{"libc6\t2.36-9+deb12u13\tamd64\tglibc\t2.36-9+deb12u13", "libc6", "glibc", "0", "2.36", "9+deb12u13"},
		{"libssl3\t3.0.17-1~deb12u2\tamd64\topenssl\t3.0.17-1~deb12u2", "libssl3", "openssl", "0", "3.0.17", "1~deb12u2"},
		{"libexample1\t1:2.3-4+b2\tamd64\texample\t1:2.3-4", "libexample1", "example", "1", "2.3", "4"},
	} {
		component, err := debianInventoryComponent(tc.row)
		if err != nil {
			t.Fatal(err)
		}
		properties := map[string]string{}
		for _, property := range component.Properties {
			properties[property.Name] = property.Value
		}
		if component.Name != tc.binary || properties["aquasecurity:trivy:SrcName"] != tc.source ||
			properties["aquasecurity:trivy:SrcEpoch"] != tc.epoch || properties["aquasecurity:trivy:SrcVersion"] != tc.upstream ||
			properties["aquasecurity:trivy:SrcRelease"] != tc.release {
			t.Fatalf("Debian source identity lost: %+v", component)
		}
		if tc.source == "example" && !strings.Contains(component.Version, "+b2") {
			t.Fatal("binary-only rebuild identity lost")
		}
	}
	if _, err := debianInventoryComponent("libc6\t2.36\tamd64"); err == nil {
		t.Fatal("binary-only inventory accepted without source identity")
	}
}

func diagnosticsSBOMFixture(t *testing.T) (string, string, imageContract) {
	t.Helper()
	bundle := t.TempDir()
	libc := "libc6\t2.36-9+deb12u14\tamd64\tglibc\t2.36-9+deb12u14"
	sysstat := "sysstat\t12.6.1-1\tamd64\tsysstat\t12.6.1-1"
	for name, data := range map[string]string{
		"manifest":   "schema=2\nunit-test binding fixture\n",
		"SHA256SUMS": "final payload hash fixture\n",
		"file-origins.tsv": "./lib/libc.so.6\tdebian\t/lib/x86_64-linux-gnu/libc.so.6\t" + libc + "\n" +
			"./libexec/sar\tdebian-source\t/sysstat-source/sysstat-12.6.1/sar\t" + sysstat + "\n",
		"debian-runtime.tsv":             libc + "\n" + sysstat + "\n",
		"debian-builder.tsv":             libc + "\n" + sysstat + "\nlinux-libc-dev\t6.1.187-1\tamd64\tlinux\t6.1.187-1\n",
		"source-builds.tsv":              "sysstat\t12.6.1-1\tDebian-signed-source; fixture\npython3.11\t3.11.2-6+deb12u9\tDebian-signed-source; fixture\n",
		"python-installed-identity.json": "{\"abi\":{\"fixture\":true},\"builtins\":[\"sys\",\"pyexpat\",\"_elementtree\"]}\n",
		"python-private-identity.json":   "{\"abi\":{\"fixture\":true},\"builtins\":[\"sys\"]}\n",
		"python-private-build.txt":       "source_version=3.11.2-6+deb12u9\nfixture compiler/config evidence\n",
	} {
		if err := os.WriteFile(filepath.Join(bundle, name), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	runtime := filepath.Join(t.TempDir(), "runtime.cdx.json")
	if err := os.WriteFile(runtime, []byte(`{"components":[{"type":"library","name":"example-go","version":"1.2.3","purl":"pkg:golang/example@v1.2.3","licenses":[{"license":{"id":"MIT"}}],"hashes":[{"alg":"SHA-256","content":"kept"}]}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	hash, err := hashFile(filepath.Join(bundle, "manifest"))
	if err != nil {
		t.Fatal(err)
	}
	return bundle, runtime, imageContract{Purpose: "admin-diagnostics", Revision: strings.Repeat("a", 40), Architecture: "amd64", ImageID: "sha256:" + strings.Repeat("b", 64), BundleManifestHash: hash}
}

func TestDiagnosticsSBOMContainsMeasuredRuntimeAndFullBoundProvenance(t *testing.T) {
	bundle, runtime, contract := diagnosticsSBOMFixture(t)
	destination := filepath.Join(t.TempDir(), "diagnostics.cdx.json")
	if err := writeDiagnosticsSBOM(bundle, contract.Revision, contract.ImageID, runtime, destination); err != nil {
		t.Fatal(err)
	}
	if err := verifyDiagnosticsSBOM(destination, contract, bundle); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	var sbom diagnosticSBOM
	if err := json.Unmarshal(data, &sbom); err != nil {
		t.Fatal(err)
	}
	// The pinned attestation action recognizes CycloneDX by this envelope.
	if sbom.Format == "" || sbom.Spec == "" || sbom.SerialNumber == "" {
		t.Fatal("generated SBOM cannot be recognized by the attestation action")
	}
	for _, component := range sbom.Components {
		if component.Name == "linux-libc-dev" {
			t.Fatal("builder-only headers misrepresented as runtime components")
		}
	}
	properties := map[string]string{}
	for _, property := range sbom.Metadata.Properties {
		properties[property.Name] = property.Value
	}
	for _, name := range diagnosticsEvidenceFiles {
		evidence, err := os.ReadFile(filepath.Join(bundle, name))
		if err != nil {
			t.Fatal(err)
		}
		if properties["emisar:evidence:"+name] != string(evidence) || properties["emisar:evidence-sha256:"+name] != fmt.Sprintf("%x", sha256.Sum256(evidence)) {
			t.Fatalf("complete source/file/builder evidence was not retained and bound: %s", name)
		}
	}
	if !strings.Contains(properties["emisar:evidence:debian-builder.tsv"], "linux-libc-dev\t6.1.187-1") ||
		!strings.Contains(string(data), `"content": "kept"`) || !strings.Contains(string(data), `"id": "MIT"`) {
		t.Fatal("builder provenance or Trivy runtime metadata was lost")
	}
	for _, tc := range []struct {
		name string
		edit func(*diagnosticSBOM)
	}{
		{"missing serial number", func(s *diagnosticSBOM) { s.SerialNumber = "" }},
		{"malformed serial number", func(s *diagnosticSBOM) { s.SerialNumber = "urn:uuid:not-a-uuid" }},
		{"wrong UUID version", func(s *diagnosticSBOM) { s.SerialNumber = "urn:uuid:00000000-0000-5000-8000-000000000000" }},
		{"wrong UUID variant", func(s *diagnosticSBOM) { s.SerialNumber = "urn:uuid:00000000-0000-4000-7000-000000000000" }},
		{"wrong SBOM format", func(s *diagnosticSBOM) { s.Format = "SPDX" }},
		{"wrong specification version", func(s *diagnosticSBOM) { s.Spec = "1.5" }},
		{"wrong document version", func(s *diagnosticSBOM) { s.Version = 0 }},
		{"source identity changed", func(s *diagnosticSBOM) { s.Components[0].Properties[1].Value = "wrong-source" }},
		{"file origins changed", func(s *diagnosticSBOM) {
			s.Components[0].Properties[len(s.Components[0].Properties)-1].Value = "guessed"
		}},
		{"runtime component omitted", func(s *diagnosticSBOM) { s.Components = s.Components[1:] }},
		{"runtime component duplicated", func(s *diagnosticSBOM) { s.Components = append(s.Components, s.Components[0]) }},
		{"builder component inserted", func(s *diagnosticSBOM) {
			component, _ := debianInventoryComponent("linux-libc-dev\t6.1.187-1\tamd64\tlinux\t6.1.187-1")
			s.Components = append(s.Components, component)
		}},
		{"file-origin evidence omitted", func(s *diagnosticSBOM) {
			for i, property := range s.Metadata.Properties {
				if property.Name == "emisar:evidence:file-origins.tsv" {
					s.Metadata.Properties[i].Value = ""
				}
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var modified diagnosticSBOM
			if err := json.Unmarshal(data, &modified); err != nil {
				t.Fatal(err)
			}
			tc.edit(&modified)
			encoded, err := json.Marshal(modified)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(destination, encoded, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := verifyDiagnosticsSBOM(destination, contract, bundle); err == nil {
				t.Fatal("modified runtime/source/evidence accepted")
			}
		})
	}
}

func TestDiagnosticsSBOMRejectsMissingOrUnmeasuredOwners(t *testing.T) {
	for _, tc := range []struct{ name, file, data string }{
		{"missing origin", "file-origins.tsv", "./libexec/sar\tdebian-source\t/sysstat-source/sysstat-12.6.1/sar\tsysstat\t12.6.1-1\tamd64\tsysstat\t12.6.1-1\n"},
		{"builder-only runtime", "debian-runtime.tsv", "linux-libc-dev\t6.1.187-1\tamd64\tlinux\t6.1.187-1\n"},
		{"unknown origin", "file-origins.tsv", "./lib/libc.so.6\tdebian-guessed\t/usr/lib/libc.so.6\tlibc6\t2.36-9\tamd64\tglibc\t2.36-9\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bundle, runtime, contract := diagnosticsSBOMFixture(t)
			if err := os.WriteFile(filepath.Join(bundle, tc.file), []byte(tc.data), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := writeDiagnosticsSBOM(bundle, contract.Revision, contract.ImageID, runtime, filepath.Join(t.TempDir(), "output")); err == nil {
				t.Fatal("incomplete measured closure accepted")
			}
		})
	}
}
