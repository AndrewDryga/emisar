package ci

import (
	"bytes"
	"compress/gzip"
	"debug/elf"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeNTPClientFixture(t *testing.T, bundle, path, name string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata/ntpsec-client", name))
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	data, err = io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	// These harvested Debian files are inspected, never executed. Their exact
	// bytes are the reviewed payload, so no test-only hash policy is needed.
	writeFixture(t, bundle, path, string(data))
}

func ntpsecScanFixture(t *testing.T) (string, []byte, diagnosticsScan) {
	t.Helper()
	data, err := os.ReadFile("testdata/diagnostics-ntpsec-findings.json")
	if err != nil {
		t.Fatal(err)
	}
	var findings []json.RawMessage
	if err := json.Unmarshal(data, &findings); err != nil {
		t.Fatal(err)
	}
	const version = "1.2.2+dfsg1-1+deb12u1"
	row := "ntpsec\t" + version + "\tamd64\tntpsec\t" + version
	pkg := scanPackage{ID: "ntpsec@" + version, Name: "ntpsec", Version: version, Arch: "amd64", SrcName: "ntpsec", SrcVersion: "1.2.2+dfsg1", SrcRelease: "1+deb12u1"}
	pkg.Identifier.PURL = "pkg:deb/debian/ntpsec@1.2.2%2Bdfsg1-1%2Bdeb12u1?arch=amd64&distro=debian-12"
	bundle, sbom, report := packageScanFixture(t, row, "libexec/ntpq", "/usr/bin/ntpq", "unused", pkg, "CVE-2026-102486", "HIGH")
	writeNTPClientFixture(t, bundle, "libexec/ntpq", "ntpq.gz")
	pythonRow := "python3-ntp\t" + version + "\tamd64\tntpsec\t" + version
	component, err := debianInventoryComponent(pythonRow)
	if err != nil {
		t.Fatal(err)
	}
	var document diagnosticSBOM
	if err := json.Unmarshal(sbom, &document); err != nil {
		t.Fatal(err)
	}
	document.Components = append(document.Components, component)
	sbom, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	pkg.Name, pkg.ID = "python3-ntp", "python3-ntp@"+version
	pkg.Identifier.PURL, pkg.Identifier.BOMRef = component.PURL, component.PURL
	report.Results[0].Packages = append(report.Results[0].Packages, pkg)
	report.Results[0].Vulnerabilities = findings
	writeFixture(t, bundle, "debian-runtime.tsv", row+"\n"+pythonRow+"\n")
	origins := "./libexec/ntpq\tdebian-extracted\t/ntp-source/extracted/usr/bin/ntpq\t" + row + "\n"
	for _, path := range []string{"ntp-1.2.2.egg-info", "ntp/libntpc.so", "ntp/packet.py", "ntp/__pycache__/packet.cpython-311.pyc"} {
		full := "python/lib/python3/dist-packages/" + path
		origins += "./" + full + "\tdebian\t/usr/lib/python3/dist-packages/" + path + "\t" + pythonRow + "\n"
		writeFixture(t, bundle, full, "client support\n")
	}
	writeFixture(t, bundle, "file-origins.tsv", origins)
	writeNTPClientFixture(t, bundle, "python/lib/python3/dist-packages/ntp/libntpc.so", "libntpc.so.gz")
	return bundle, sbom, report
}

func TestDiagnosticsScanAssessesOnlyTheNTPQueryClientPayload(t *testing.T) {
	// Two harvested findings stopped an otherwise green release even though the
	// final bundle shipped ntpq and libntpc, not ntpd's vulnerable NTS parser.
	bundle, sbom, report := ntpsecScanFixture(t)
	raw, _ := json.Marshal(report)
	before := bytes.Clone(raw)
	// Marshal compacts the harvested JSON; compare with the exact classifier
	// input, including its original finding fields and scanner metadata.
	var input diagnosticsScan
	if err := json.Unmarshal(raw, &input); err != nil {
		t.Fatal(err)
	}
	assessed, accepted, blocking, err := classifyDiagnosticsScan(bundle, sbom, raw, time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC))
	if err != nil || len(assessed) != 2 || len(accepted) != 0 || len(blocking) != 0 {
		t.Fatalf("client-only payload: assessed=%d accepted=%d blocking=%d err=%v", len(assessed), len(accepted), len(blocking), err)
	}
	if !bytes.Equal(raw, before) || !bytes.Equal(assessed[0].Finding, input.Results[0].Vulnerabilities[0]) || !bytes.Equal(assessed[1].Finding, input.Results[0].Vulnerabilities[1]) {
		t.Fatal("raw NTPsec findings changed")
	}
	assessed, _, blocking, err = classifyDiagnosticsScan(bundle, sbom, raw, time.Date(2026, 11, 8, 0, 0, 0, 0, time.UTC))
	if err != nil || len(assessed) != 0 || len(blocking) != 2 {
		t.Fatalf("NTPsec assessment outlived expiry: assessed=%d blocking=%d err=%v", len(assessed), len(blocking), err)
	}
}

func TestDiagnosticsScanRejectsNTPDaemonOrCopiedParser(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(string)
	}{
		{"daemon outside assessed package", func(b string) { writeFixture(t, b, "other/ntpd", "daemon") }},
		{"daemon library outside assessed package", func(b string) { writeFixture(t, b, "other/libntpd.so", "daemon") }},
		{"parser source outside assessed package", func(b string) { writeFixture(t, b, "other/nts_extens.c", "parser") }},
		{"renamed parser ELF", func(b string) {
			scanELFFixture(t, filepath.Join(b, "other/helper"), "extens_server_recv", elf.ELFCLASS64)
		}},
		{"daemon renamed as query client", func(b string) { scanELFFixture(t, filepath.Join(b, "libexec/ntpq"), "main", elf.ELFCLASS64) }},
		{"native code renamed as Python", func(b string) {
			scanELFFixture(t, filepath.Join(b, "python/lib/python3/dist-packages/ntp/packet.py"), "main", elf.ELFCLASS64)
		}},
		{"uninspectable native helper", func(b string) { writeFixture(t, b, "python/lib/python3/dist-packages/ntp/libntpc.so", "not ELF") }},
		{"different helper architecture", func(b string) {
			scanELFFixture(t, filepath.Join(b, "python/lib/python3/dist-packages/ntp/libntpc.so"), "ntpc_lfptofloat", elf.ELFCLASS32)
		}},
		{"modified query client", func(b string) {
			file := filepath.Join(b, "libexec/ntpq")
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			writeFixture(t, b, "libexec/ntpq", string(data)+"# changed\n")
		}},
		{"modified native helper preserving symbols", func(b string) {
			path := "python/lib/python3/dist-packages/ntp/libntpc.so"
			data, err := os.ReadFile(filepath.Join(b, path))
			if err != nil {
				t.Fatal(err)
			}
			writeFixture(t, b, path, string(data)+"changed")
		}},
		{"unexpected source-owned module", func(b string) {
			data, err := os.ReadFile(filepath.Join(b, "file-origins.tsv"))
			if err != nil {
				t.Fatal(err)
			}
			last := strings.Split(strings.TrimSpace(string(data)), "\n")
			row := strings.ReplaceAll(last[len(last)-1], "ntp/__pycache__/packet.cpython-311.pyc", "ntp/server.py")
			writeFixture(t, b, "file-origins.tsv", string(data)+row+"\n")
			writeFixture(t, b, "python/lib/python3/dist-packages/ntp/server.py", "server")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bundle, sbom, report := ntpsecScanFixture(t)
			tc.edit(bundle)
			raw, _ := json.Marshal(report)
			if _, _, _, err := classifyDiagnosticsScan(bundle, sbom, raw, time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)); err == nil {
				t.Fatal("payload without client-only proof accepted")
			}
		})
	}
}
