package ci

import (
	"context"
	"encoding/json"
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
