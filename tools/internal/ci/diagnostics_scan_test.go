package ci

import (
	"bytes"
	"debug/elf"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A small inspectable ELF tests the classifier's architecture/symbol predicates,
// not runtime execution. Real tool behavior belongs to native qualification.
func scanELFFixture(t *testing.T, path, symbol string, class elf.Class) {
	t.Helper()
	var data bytes.Buffer
	var header elf.Header64
	copy(header.Ident[:], []byte{0x7f, 'E', 'L', 'F', byte(class), byte(elf.ELFDATA2LSB), byte(elf.EV_CURRENT)})
	header.Type, header.Machine, header.Version = uint16(elf.ET_DYN), uint16(elf.EM_X86_64), uint32(elf.EV_CURRENT)
	header.Ehsize, header.Shoff, header.Shentsize, header.Shnum = 64, 128, 64, 3
	if err := binary.Write(&data, binary.LittleEndian, header); err != nil {
		t.Fatal(err)
	}
	for _, value := range []elf.Sym64{{}, {Name: 1, Info: byte(elf.STB_GLOBAL)<<4 | byte(elf.STT_FUNC), Shndx: uint16(elf.SHN_UNDEF)}} {
		if err := binary.Write(&data, binary.LittleEndian, value); err != nil {
			t.Fatal(err)
		}
	}
	strtab := append([]byte{0}, append([]byte(symbol), 0)...)
	// Place the string table after the three section headers.
	data.Write(make([]byte, 128-data.Len()))
	sections := []elf.Section64{{}, {Type: uint32(elf.SHT_DYNSYM), Off: 64, Size: 48, Link: 2, Entsize: 24}, {Type: uint32(elf.SHT_STRTAB), Off: 320, Size: uint64(len(strtab))}}
	for _, section := range sections {
		if err := binary.Write(&data, binary.LittleEndian, section); err != nil {
			t.Fatal(err)
		}
	}
	data.Write(strtab)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

func scanFixture(t *testing.T) (string, []byte, diagnosticsScan) {
	t.Helper()
	bundle := t.TempDir()
	row := "zlib1g\t1:1.2.13.dfsg-1\tamd64\tzlib\t1:1.2.13.dfsg-1"
	writeFixture(t, bundle, "debian-runtime.tsv", row+"\n")
	writeFixture(t, bundle, "file-origins.tsv", "./lib/libz.so.1\tdebian\t/usr/lib/x86_64-linux-gnu/libz.so.1.2.13\t"+row+"\n")
	scanELFFixture(t, filepath.Join(bundle, "lib/libz.so.1"), "zlibVersion", elf.ELFCLASS64)
	component, err := debianInventoryComponent(row)
	if err != nil {
		t.Fatal(err)
	}
	language := sbomComponent{Reference: "pkg:pypi/ntpsec@1.2.2", Name: "ntpsec", Version: "1.2.2", PURL: "pkg:pypi/ntpsec@1.2.2"}
	sbom, err := json.Marshal(diagnosticSBOM{Format: "CycloneDX", Components: []sbomComponent{component, language}})
	if err != nil {
		t.Fatal(err)
	}
	var report diagnosticsScan
	report.SchemaVersion, report.ArtifactType = 2, "cyclonedx"
	report.Metadata.OS.Family, report.Metadata.OS.Name = "debian", "12"
	// Keep the real scanner's literal epoch in PURL and escaped epoch in BOMRef.
	pkg := scanPackage{ID: "zlib1g@1:1.2.13.dfsg-1", Name: "zlib1g", Version: "1:1.2.13.dfsg-1", Arch: "amd64", SrcName: "zlib", SrcVersion: "1.2.13.dfsg", SrcRelease: "1", SrcEpoch: 1}
	pkg.Identifier.PURL = "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12"
	pkg.Identifier.BOMRef = component.PURL
	finding := scanFinding{VulnerabilityID: "CVE-2023-45853", PkgID: pkg.ID, PkgName: pkg.Name, InstalledVersion: pkg.Version, Severity: "CRITICAL", PkgIdentifier: pkg.Identifier}
	rawFinding, _ := json.Marshal(finding)
	reportData := map[string]any{"SchemaVersion": 2, "ArtifactType": "cyclonedx", "Metadata": report.Metadata, "Results": []any{
		map[string]any{"Class": "os-pkgs", "Type": "debian", "Target": "/tmp/bound.cdx.json (debian 12)", "Packages": []scanPackage{pkg}, "Vulnerabilities": []json.RawMessage{rawFinding}},
		map[string]any{"Class": "lang-pkgs", "Type": "python-pkg", "Target": "Python", "Packages": []any{map[string]any{"ID": "ntpsec@1.2.2", "Name": "ntpsec", "Version": "1.2.2", "Identifier": map[string]any{"PURL": language.PURL, "BOMRef": language.Reference}}}},
	}}
	data, _ := json.Marshal(reportData)
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return bundle, sbom, report
}

func TestDiagnosticsScanExactArtifactAssessmentAndUnchangedDuplicates(t *testing.T) {
	bundle, sbom, report := scanFixture(t)
	report.Results[0].Vulnerabilities = append(report.Results[0].Vulnerabilities, report.Results[0].Vulnerabilities[0])
	raw, _ := json.Marshal(report)
	before := bytes.Clone(raw)
	assessed, blocking, err := classifyDiagnosticsScan(bundle, sbom, raw, time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC))
	if err != nil || len(assessed) != 2 || len(blocking) != 0 || !bytes.Equal(before, raw) {
		t.Fatalf("exact non-affected assessment: assessed=%d blocking=%d err=%v", len(assessed), len(blocking), err)
	}
	if !bytes.Equal(assessed[0].Finding, report.Results[0].Vulnerabilities[0]) {
		t.Fatal("raw finding was rewritten")
	}
}

func TestDiagnosticsScanFailsClosedForMissingOrChangedEvidence(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(string, *diagnosticsScan)
	}{
		{"missing PURL", func(_ string, r *diagnosticsScan) { r.Results[0].Packages[0].Identifier.PURL = "" }},
		{"different architecture", func(_ string, r *diagnosticsScan) { r.Results[0].Packages[0].Arch = "arm64" }},
		{"different source", func(_ string, r *diagnosticsScan) { r.Results[0].Packages[0].SrcName = "another-source" }},
		{"different source version", func(_ string, r *diagnosticsScan) { r.Results[0].Packages[0].SrcRelease = "2" }},
		{"missing runtime package", func(_ string, r *diagnosticsScan) { r.Results[0].Packages = nil }},
		{"duplicate runtime package", func(_ string, r *diagnosticsScan) {
			r.Results[0].Packages = append(r.Results[0].Packages, r.Results[0].Packages[0])
		}},
		{"missing language target", func(_ string, r *diagnosticsScan) { r.Results = r.Results[:1] }},
		{"changed language version", func(_ string, r *diagnosticsScan) { r.Results[1].Packages[0].Version = "2.0.0" }},
		{"unknown target", func(_ string, r *diagnosticsScan) { r.Results[1].Type = "unknown" }},
		{"wrong schema", func(_ string, r *diagnosticsScan) { r.SchemaVersion = 3 }},
		{"wrong artifact", func(_ string, r *diagnosticsScan) { r.ArtifactType = "container_image" }},
		{"missing finding identity", func(_ string, r *diagnosticsScan) {
			var finding scanFinding
			_ = json.Unmarshal(r.Results[0].Vulnerabilities[0], &finding)
			finding.PkgIdentifier.PURL = ""
			r.Results[0].Vulnerabilities[0], _ = json.Marshal(finding)
		}},
		{"affected file", func(b string, _ *diagnosticsScan) { writeFixture(t, b, "python/pyminizip.py", "present\n") }},
		{"affected symbol", func(b string, _ *diagnosticsScan) {
			scanELFFixture(t, filepath.Join(b, "lib/libz.so.1"), "zipOpenNewFileInZip4_64", elf.ELFCLASS64)
		}},
		{"unreadable ELF", func(b string, _ *diagnosticsScan) { writeFixture(t, b, "lib/libz.so.1", "\x7fELFbroken") }},
		{"non-ELF library", func(b string, _ *diagnosticsScan) { writeFixture(t, b, "lib/libz.so.1", "not ELF") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bundle, sbom, report := scanFixture(t)
			tc.edit(bundle, &report)
			raw, _ := json.Marshal(report)
			if _, _, err := classifyDiagnosticsScan(bundle, sbom, raw, time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)); err == nil {
				t.Fatal("incomplete evidence accepted")
			}
		})
	}
}

func TestDiagnosticsScanBlocksUnknownExpiredAndLanguageFindings(t *testing.T) {
	for _, kind := range []string{"unknown", "expired", "language"} {
		t.Run(kind, func(t *testing.T) {
			bundle, sbom, report := scanFixture(t)
			now := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
			var finding scanFinding
			_ = json.Unmarshal(report.Results[0].Vulnerabilities[0], &finding)
			switch kind {
			case "unknown":
				finding.VulnerabilityID = "CVE-2099-1234"
			case "expired":
				now = time.Date(2026, 11, 8, 0, 0, 0, 0, time.UTC)
			case "language":
				pkg := report.Results[1].Packages[0]
				finding.PkgName, finding.PkgID, finding.InstalledVersion, finding.PkgIdentifier = pkg.Name, pkg.ID, pkg.Version, pkg.Identifier
			}
			rawFinding, _ := json.Marshal(finding)
			if kind == "language" {
				report.Results[0].Vulnerabilities = nil
				report.Results[1].Vulnerabilities = []json.RawMessage{rawFinding}
			} else {
				report.Results[0].Vulnerabilities = []json.RawMessage{rawFinding}
			}
			raw, _ := json.Marshal(report)
			assessed, blocking, err := classifyDiagnosticsScan(bundle, sbom, raw, now)
			if err != nil || len(assessed) != 0 || len(blocking) != 1 || !bytes.Equal(blocking[0], rawFinding) {
				t.Fatalf("finding silently lost: assessed=%d blocking=%d err=%v", len(assessed), len(blocking), err)
			}
		})
	}
}

func TestDebianPURLDoesNotBroadenEpochOrIdentity(t *testing.T) {
	for _, version := range []string{"1:1.2.13.dfsg-1", "1%3A1.2.13.dfsg-1"} {
		if !debianPURL("pkg:deb/debian/zlib1g@"+version+"?arch=amd64&distro=debian-12", "zlib1g", "1:1.2.13.dfsg-1", "amd64") {
			t.Fatal("equivalent epoch encoding rejected")
		}
	}
	for _, changed := range []string{"pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=arm64&distro=debian-12", "pkg:deb/debian/zlib1g@1.2.13.dfsg-1?arch=amd64&distro=debian-12", "pkg:deb/debian/other@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12", "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&arch=all&distro=debian-12"} {
		if debianPURL(changed, "zlib1g", "1:1.2.13.dfsg-1", "amd64") {
			t.Fatal("different PURL identity accepted")
		}
	}
}

func TestDebianPURLPreservesEncodedPackageNameIdentity(t *testing.T) {
	// Trivy 0.74 escapes the C++ package name in PURL but not its BOMRef.
	for _, name := range []string{"libstdc++6", "libstdc%2B%2B6", "libstdc%2b%2b6"} {
		if !debianPURL("pkg:deb/debian/"+name+"@12.2.0-14%2Bdeb12u1?arch=amd64&distro=debian-12", "libstdc++6", "12.2.0-14+deb12u1", "amd64") {
			t.Fatalf("equivalent package name encoding rejected: %s", name)
		}
	}
	for _, name := range []string{"libstdc%252B%252B6", "libstdc%2B6", "libstdc%2F%2B6", "libstdc%ZZ6"} {
		if debianPURL("pkg:deb/debian/"+name+"@12.2.0-14%2Bdeb12u1?arch=amd64&distro=debian-12", "libstdc++6", "12.2.0-14+deb12u1", "amd64") {
			t.Fatalf("different or malformed package name accepted: %s", name)
		}
	}
}

func TestFindmntAssessmentRejectsUnreviewedBytes(t *testing.T) {
	bundle := t.TempDir()
	writeFixture(t, bundle, "libexec/findmnt", "unreviewed replacement")
	if err := proveReadOnlyFindmnt(bundle, nil); err == nil || !strings.Contains(err.Error(), "exact authenticated") {
		t.Fatalf("unreviewed libmount consumer accepted: %v", err)
	}
}
