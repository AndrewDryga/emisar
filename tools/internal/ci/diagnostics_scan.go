package ci

import (
	"context"
	"crypto/sha256"
	"debug/elf"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"
)

type scanPackage struct {
	ID, Name, Version, Arch, SrcName, SrcVersion, SrcRelease string
	SrcEpoch                                                 int
	Identifier                                               struct{ PURL, BOMRef string }
}

type scanFinding struct {
	VulnerabilityID, PkgID, PkgName, InstalledVersion, Severity string
	PkgIdentifier                                               struct{ PURL, BOMRef string }
}

type diagnosticsScan struct {
	SchemaVersion int
	ArtifactType  string
	Metadata      struct{ OS struct{ Family, Name string } }
	Results       []struct {
		Class, Type, Target string
		Packages            []scanPackage
		Vulnerabilities     []json.RawMessage
	}
}

type nonaffectedRule struct {
	Source, Version, Predicate, Reference string
	Binaries                              []string
}

// Finite, diagnostics-only assessments, not an ignore list. Every use requires
// the exact signed source/binary identity AND proof from the final bundle. New
// advisories, package updates and expired assessments block publication.
var diagnosticsNonaffected = map[string]nonaffectedRule{
	// The fix changes ntpd/nts_extens.c::extens_server_recv. This exact Debian
	// subset ships the Python query client and its separate libntpc, not ntpd.
	"CVE-2026-102486": {"ntpsec", "1.2.2+dfsg1-1+deb12u1", "ntpq-no-nts-daemon", "https://github.com/ntpsec/ntpsec/commit/7cc079387a0c8f94a4a82ebd0fc3cbe32f705557", []string{"ntpsec", "python3-ntp"}},
	"CVE-2023-33204":  {"sysstat", "12.6.1-1", "sysstat-elf64", "https://security-tracker.debian.org/tracker/CVE-2023-33204", []string{"sysstat"}},
	"CVE-2023-45853":  {"zlib", "1:1.2.13.dfsg-1", "no-minizip", "https://security-tracker.debian.org/tracker/CVE-2023-45853", []string{"zlib1g"}},
	"CVE-2025-69720":  {"ncurses", "6.4-4", "no-infocmp", "https://security-tracker.debian.org/tracker/CVE-2025-69720", []string{"libncursesw6", "libtinfo6"}},
	"CVE-2026-16742":  {"systemd", "252.39-1~deb12u2", "no-homed", "https://github.com/systemd/systemd/security/advisories/GHSA-jm29-p7hh-vjhv", []string{"libsystemd0", "libudev1"}},
	"CVE-2026-11940":  {"python3.11", "3.11.2-6+deb12u9", "no-tarfile", "https://github.com/python/cpython/commit/be13e86f6b9788a6f4d0419dffef72cbae5865c9", []string{"libpython3.11-minimal", "libpython3.11-stdlib", "python3.11-minimal"}},
	"CVE-2026-7210":   {"python3.11", "3.11.2-6+deb12u9", "no-expat", "https://mail.python.org/archives/list/security-announce@python.org/message/PNY5OMBDPM2FRUZTWFFPJ6LISWKV627K/", []string{"libpython3.11-minimal", "libpython3.11-stdlib", "python3.11-minimal"}},
	"CVE-2026-53613":  {"util-linux", "2.38.1-5+deb12u3", "findmnt-read-only", "https://github.com/util-linux/util-linux/security/advisories/GHSA-8gj5-72r3-428g", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
	"CVE-2026-76642":  {"util-linux", "2.38.1-5+deb12u3", "findmnt-read-only", "https://github.com/util-linux/util-linux/security/advisories/GHSA-m25x-3hj9-m26f", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
	"CVE-2026-78408":  {"util-linux", "2.38.1-5+deb12u3", "findmnt-read-only", "https://github.com/util-linux/util-linux/security/advisories/GHSA-55fx-f4gg-cfhj", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
	"CVE-2026-78409":  {"util-linux", "2.38.1-5+deb12u3", "findmnt-read-only", "https://github.com/util-linux/util-linux/security/advisories/GHSA-8f2p-47x3-43mv", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
	"CVE-2026-78410":  {"util-linux", "2.38.1-5+deb12u3", "findmnt-read-only", "https://github.com/util-linux/util-linux/security/advisories/GHSA-rh77-686x-2f2m", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
}

// Owner-accepted risks, not non-affected assessments: the final bundle cannot
// prove these unreachable, so the founder accepted each one by name and date.
// They require the same exact source/binary identity and expire with the
// assessments, and the decision file lists them apart from proved ones.
var diagnosticsOwnerAccepted = map[string]nonaffectedRule{
	// Accepted 2026-10-20. On the privileged host, findmnt's tag lookups and lvm
	// can reach libblkid partition probing, but exploiting the DOS partition
	// parser needs a crafted partition table on an attached disk, which already
	// takes root or hypervisor access. Bookworm has no fix; upstream 2.41.4 does.
	"CVE-2026-53615": {"util-linux", "2.38.1-5+deb12u3", "owner-accepted", "https://github.com/util-linux/util-linux/security/advisories/GHSA-h4rw-gv36-wmp5", []string{"bsdutils", "libblkid1", "libmount1", "libsmartcols1", "libuuid1", "util-linux", "util-linux-extra"}},
}

const diagnosticsAssessmentExpiry = "2026-11-08"

type diagnosticAssessment struct {
	Finding json.RawMessage `json:"finding"`
	Package scanPackage     `json:"package"`
	Rule    nonaffectedRule `json:"rule"`
}

// DiagnosticsScan classifies one immutable raw Trivy report. It never changes
// that report or suppresses findings in other targets (including Go/Python).
func DiagnosticsScan(ctx context.Context, root, revision, image, sbomPath, rawPath, decisionPath string) error {
	identity, err := inspectImage(ctx, image)
	if err != nil {
		return err
	}
	if err := validateImageIdentity(identity, "admin-diagnostics", revision); err != nil {
		return err
	}
	bundle, cleanup, err := extractDiagnostics(ctx, root, image, revision)
	if err != nil {
		return err
	}
	defer cleanup()
	manifestHash, err := hashFile(filepath.Join(bundle, "manifest"))
	if err != nil {
		return err
	}
	contract := imageContract{Purpose: "admin-diagnostics", Revision: revision, Architecture: "amd64", ImageID: identity.ID, BundleManifestHash: manifestHash}
	if err := verifyDiagnosticsSBOM(sbomPath, contract, bundle); err != nil {
		return err
	}
	raw, err := os.ReadFile(rawPath)
	if err != nil {
		return err
	}
	sbomData, err := os.ReadFile(sbomPath)
	if err != nil {
		return err
	}
	assessments, accepted, blocking, err := classifyDiagnosticsScan(bundle, sbomData, raw, time.Now().UTC())
	if err != nil {
		return err
	}
	bindings := map[string]string{"image_id": identity.ID, "revision": revision, "bundle_manifest_sha256": manifestHash}
	for key, path := range map[string]string{"raw_scan_sha256": rawPath, "sbom_sha256": sbomPath, "policy_sha256": filepath.Join(root, "tools/internal/ci/diagnostics_scan.go")} {
		bindings[key], err = hashFile(path)
		if err != nil {
			return err
		}
	}
	decision := struct {
		Bindings      map[string]string      `json:"bindings"`
		Expires       string                 `json:"expires"`
		Assessed      []diagnosticAssessment `json:"non_affected"`
		OwnerAccepted []diagnosticAssessment `json:"owner_accepted"`
		Blocking      []json.RawMessage      `json:"blocking"`
		EvaluatedAt   time.Time              `json:"evaluated_at"`
	}{bindings, diagnosticsAssessmentExpiry, assessments, accepted, blocking, time.Now().UTC()}
	data, err := json.MarshalIndent(decision, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(decisionPath, append(data, '\n'), 0o600); err != nil {
		return err
	}
	if len(blocking) != 0 {
		return fmt.Errorf("diagnostics scan has %d unassessed HIGH/CRITICAL findings; see %s", len(blocking), decisionPath)
	}
	fmt.Printf("Diagnostics scan: %d exact-artifact non-affected assessments, %d owner-accepted risks; no blocking findings\n", len(assessments), len(accepted))
	return nil
}

func debianPURL(value, name, version, arch string) bool {
	base, query, ok := strings.Cut(value, "?")
	if !ok || !strings.HasPrefix(base, "pkg:deb/debian/") {
		return false
	}
	gotName, gotVersion, ok := strings.Cut(strings.TrimPrefix(base, "pkg:deb/debian/"), "@")
	decodedName, nameErr := url.PathUnescape(gotName)
	decoded, err := url.PathUnescape(gotVersion)
	qualifiers, queryErr := url.ParseQuery(query)
	return ok && nameErr == nil && err == nil && queryErr == nil && decodedName == name && decoded == version &&
		len(qualifiers) == 2 && len(qualifiers["arch"]) == 1 && len(qualifiers["distro"]) == 1 &&
		qualifiers.Get("arch") == arch && qualifiers.Get("distro") == "debian-12"
}

func scanSourceVersion(pkg scanPackage) string {
	version := pkg.SrcVersion + "-" + pkg.SrcRelease
	if pkg.SrcEpoch != 0 {
		version = strconv.Itoa(pkg.SrcEpoch) + ":" + version
	}
	return version
}

func classifyDiagnosticsScan(bundle string, sbomData, raw []byte, now time.Time) ([]diagnosticAssessment, []diagnosticAssessment, []json.RawMessage, error) {
	var report diagnosticsScan
	if err := json.Unmarshal(raw, &report); err != nil {
		return nil, nil, nil, err
	}
	if report.SchemaVersion != 2 || report.ArtifactType != "cyclonedx" || report.Metadata.OS.Family != "debian" || report.Metadata.OS.Name != "12" || len(report.Results) == 0 {
		return nil, nil, nil, fmt.Errorf("malformed diagnostics scan identity")
	}
	expected, err := diagnosticsDebianComponents(bundle)
	if err != nil {
		return nil, nil, nil, err
	}
	components := map[string]sbomComponent{}
	for _, component := range expected {
		components[component.Name] = component
	}
	var sbom diagnosticSBOM
	if err := json.Unmarshal(sbomData, &sbom); err != nil {
		return nil, nil, nil, err
	}
	languages := map[string]sbomComponent{}
	for _, component := range sbom.Components {
		if strings.HasPrefix(component.PURL, "pkg:golang/") || strings.HasPrefix(component.PURL, "pkg:pypi/") {
			if _, duplicate := languages[component.PURL]; duplicate {
				return nil, nil, nil, fmt.Errorf("duplicate language SBOM component")
			}
			languages[component.PURL] = component
		}
	}
	languagePackages := map[string]scanPackage{}
	seen, packages := map[string]bool{}, map[string]scanPackage{}
	debianTargets := 0
	for _, result := range report.Results {
		switch result.Type {
		case "debian":
			if result.Class != "os-pkgs" || !strings.HasSuffix(result.Target, " (debian 12)") {
				return nil, nil, nil, fmt.Errorf("malformed Debian scan target")
			}
			debianTargets++
			for _, pkg := range result.Packages {
				component, exists := components[pkg.Name]
				props := map[string]string{}
				for _, prop := range component.Properties {
					props[prop.Name] = prop.Value
				}
				epoch, epochErr := strconv.Atoi(props["aquasecurity:trivy:SrcEpoch"])
				if !exists || seen[pkg.Name] || pkg.ID != pkg.Name+"@"+pkg.Version || pkg.Version != component.Version ||
					(pkg.Arch != "amd64" && pkg.Arch != "all") || !debianPURL(pkg.Identifier.PURL, pkg.Name, pkg.Version, pkg.Arch) ||
					!debianPURL(pkg.Identifier.BOMRef, pkg.Name, pkg.Version, pkg.Arch) ||
					pkg.SrcName != props["aquasecurity:trivy:SrcName"] || pkg.SrcVersion != props["aquasecurity:trivy:SrcVersion"] ||
					pkg.SrcRelease != props["aquasecurity:trivy:SrcRelease"] || epochErr != nil || pkg.SrcEpoch != epoch {
					return nil, nil, nil, fmt.Errorf("scan package differs from bound runtime inventory: %s", pkg.Name)
				}
				// Match the inventory's actual architecture, not just an accepted one.
				if !debianPURL(component.PURL, pkg.Name, pkg.Version, pkg.Arch) {
					return nil, nil, nil, fmt.Errorf("scan package architecture differs: %s", pkg.Name)
				}
				seen[pkg.Name], packages[pkg.Name] = true, pkg
			}
		case "gobinary", "python-pkg":
			if result.Class != "lang-pkgs" || len(result.Packages) == 0 {
				return nil, nil, nil, fmt.Errorf("malformed language scan target")
			}
			prefix := "pkg:golang/"
			if result.Type == "python-pkg" {
				prefix = "pkg:pypi/"
			}
			for _, pkg := range result.Packages {
				component, exists := languages[pkg.Identifier.PURL]
				_, duplicate := languagePackages[pkg.Identifier.PURL]
				if !exists || duplicate || !strings.HasPrefix(pkg.Identifier.PURL, prefix) || pkg.Identifier.BOMRef != component.Reference || pkg.Name != component.Name || pkg.Version != component.Version || pkg.ID != pkg.Name+"@"+pkg.Version {
					return nil, nil, nil, fmt.Errorf("language scan package differs from bound SBOM: %s", pkg.Name)
				}
				languagePackages[pkg.Identifier.PURL] = pkg
			}
		default:
			return nil, nil, nil, fmt.Errorf("unknown diagnostics scan target: %s", result.Type)
		}
	}
	if debianTargets != 1 || len(seen) != len(components) || len(languagePackages) != len(languages) {
		return nil, nil, nil, fmt.Errorf("scan omits or duplicates bound runtime packages")
	}
	var assessed, accepted []diagnosticAssessment
	var blocking []json.RawMessage
	proved := map[string]bool{}
	for _, result := range report.Results {
		for _, rawFinding := range result.Vulnerabilities {
			var finding scanFinding
			if err := json.Unmarshal(rawFinding, &finding); err != nil || finding.VulnerabilityID == "" || finding.PkgName == "" || finding.InstalledVersion == "" || (finding.Severity != "HIGH" && finding.Severity != "CRITICAL") {
				return nil, nil, nil, fmt.Errorf("malformed HIGH/CRITICAL scan finding")
			}
			pkg, exists := packages[finding.PkgName]
			if result.Type == "debian" && (!exists || finding.PkgID != pkg.ID || finding.InstalledVersion != pkg.Version ||
				!debianPURL(finding.PkgIdentifier.PURL, pkg.Name, pkg.Version, pkg.Arch) ||
				!debianPURL(finding.PkgIdentifier.BOMRef, pkg.Name, pkg.Version, pkg.Arch)) {
				return nil, nil, nil, fmt.Errorf("finding lacks exact bound Debian identity: %s", finding.VulnerabilityID)
			}
			if result.Type != "debian" {
				language, exists := languagePackages[finding.PkgIdentifier.PURL]
				if !exists || finding.PkgName != language.Name || finding.PkgID != language.ID || finding.InstalledVersion != language.Version || finding.PkgIdentifier.BOMRef != language.Identifier.BOMRef {
					return nil, nil, nil, fmt.Errorf("finding lacks exact bound language identity: %s", finding.VulnerabilityID)
				}
			}
			rule, known := diagnosticsNonaffected[finding.VulnerabilityID]
			ownerAccepted := false
			if !known {
				rule, ownerAccepted = diagnosticsOwnerAccepted[finding.VulnerabilityID]
			}
			binaryVersion := rule.Version
			if rule.Source == "util-linux" && pkg.Name == "bsdutils" {
				binaryVersion = "1:" + binaryVersion
			}
			if result.Type != "debian" || !(known || ownerAccepted) || now.Format("2006-01-02") >= diagnosticsAssessmentExpiry ||
				pkg.SrcName != rule.Source || scanSourceVersion(pkg) != rule.Version || pkg.Version != binaryVersion || !slices.Contains(rule.Binaries, pkg.Name) {
				blocking = append(blocking, rawFinding)
				continue
			}
			if ownerAccepted {
				accepted = append(accepted, diagnosticAssessment{rawFinding, pkg, rule})
				continue
			}
			if !proved[rule.Predicate] {
				if err := proveDiagnosticsNonaffected(bundle, rule); err != nil {
					return nil, nil, nil, fmt.Errorf("%s non-affected predicate failed: %w", finding.VulnerabilityID, err)
				}
				proved[rule.Predicate] = true
			}
			assessed = append(assessed, diagnosticAssessment{rawFinding, pkg, rule})
		}
	}
	return assessed, accepted, blocking, nil
}

type diagnosticELF struct {
	Class     elf.Class
	Machine   elf.Machine
	Libraries []string
	Symbols   []elf.Symbol
}

func diagnosticsELFs(bundle string) (map[string]diagnosticELF, error) {
	files := map[string]diagnosticELF{}
	err := filepath.WalkDir(bundle, func(path string, entry os.DirEntry, err error) error {
		if err != nil || !entry.Type().IsRegular() {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if len(data) < 4 || string(data[:4]) != "\x7fELF" {
			return nil
		}
		file, err := elf.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		libraries, err := file.ImportedLibraries()
		if err != nil {
			return err
		}
		dynamic, err := file.DynamicSymbols()
		if err != nil && !errors.Is(err, elf.ErrNoSymbols) {
			return err
		}
		static, err := file.Symbols()
		if err != nil && !errors.Is(err, elf.ErrNoSymbols) {
			return err
		}
		if len(dynamic)+len(static) == 0 {
			return fmt.Errorf("ELF has no inspectable symbols: %s", path)
		}
		relative, err := filepath.Rel(bundle, path)
		if err != nil {
			return err
		}
		files["./"+filepath.ToSlash(relative)] = diagnosticELF{file.Class, file.Machine, libraries, append(dynamic, static...)}
		return nil
	})
	return files, err
}

func proveDiagnosticsNonaffected(bundle string, rule nonaffectedRule) error {
	origins, err := readDiagnosticsOrigins(bundle)
	if err != nil {
		return err
	}
	var owned []string
	for identity, rows := range origins {
		fields := strings.Split(identity, "\t")
		if fields[3] == rule.Source {
			if fields[4] != rule.Version {
				return fmt.Errorf("multiple source versions in assessed bundle")
			}
			for _, row := range rows {
				owned = append(owned, strings.Split(row, "\t")[0])
			}
		}
	}
	if len(owned) == 0 {
		return fmt.Errorf("assessed source owns no runtime files")
	}
	elfs, err := diagnosticsELFs(bundle)
	if err != nil {
		return err
	}
	allowOnly := func(allowed ...string) error {
		for _, path := range owned {
			if !slices.Contains(allowed, path) {
				return fmt.Errorf("unexpected assessed source file: %s", path)
			}
			if file, exists := elfs[path]; !exists || file.Class != elf.ELFCLASS64 || file.Machine != elf.EM_X86_64 {
				return fmt.Errorf("assessed source file is not inspectable native amd64 ELF: %s", path)
			}
		}
		return nil
	}
	switch rule.Predicate {
	case "sysstat-elf64":
		if err := allowOnly("./libexec/sar", "./libexec/sadc", "./libexec/iostat"); err != nil {
			return err
		}
		if len(owned) != 3 {
			return fmt.Errorf("incomplete sysstat source build")
		}
		for _, path := range owned {
			if file := elfs[path]; file.Class != elf.ELFCLASS64 || file.Machine != elf.EM_X86_64 {
				return fmt.Errorf("sysstat is not the unaffected 64-bit build")
			}
		}
	case "no-minizip":
		if err := allowOnly("./lib/libz.so.1"); err != nil {
			return err
		}
	case "no-infocmp":
		if err := allowOnly("./lib/libncursesw.so.6", "./lib/libpanelw.so.6", "./lib/libtinfo.so.6"); err != nil {
			return err
		}
	case "no-homed":
		if err := allowOnly("./lib/libsystemd.so.0", "./lib/libudev.so.1"); err != nil {
			return err
		}
	case "no-tarfile", "no-expat":
		if err := provePrivatePython(bundle); err != nil {
			return err
		}
	case "findmnt-read-only":
		if err := proveReadOnlyFindmnt(bundle, elfs); err != nil {
			return err
		}
	case "ntpq-no-nts-daemon":
		if err := proveNTPQueryClient(bundle, owned, elfs); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unknown non-affected predicate")
	}
	for path, file := range elfs {
		for _, library := range file.Libraries {
			if strings.HasPrefix(library, "libexpat") {
				return fmt.Errorf("affected library imported by %s: %s", path, library)
			}
		}
		for _, symbol := range file.Symbols {
			if symbol.Name == "PyInit_pyexpat" || symbol.Name == "PyInit__elementtree" || strings.HasPrefix(symbol.Name, "zipOpenNewFileInZip4_") {
				return fmt.Errorf("affected implementation symbol in %s: %s", path, symbol.Name)
			}
		}
	}
	// Inspect the entire payload, not just paths owned by the finding's package:
	// a copied parser or embedded vulnerable implementation defeats absence.
	return filepath.WalkDir(bundle, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := entry.Name()
		if strings.Contains(name, "minizip") || strings.Contains(name, "infocmp") || strings.Contains(name, "homed") || strings.Contains(name, "homework") ||
			strings.HasPrefix(name, "libexpat") || strings.Contains(name, "pyexpat") || strings.Contains(name, "_elementtree") || strings.HasPrefix(name, "tarfile.") || name == "xml" {
			return fmt.Errorf("affected implementation present: %s", path)
		}
		return nil
	})
}

// NTPsec 1.2.2's ntpd/wscript links nts_extens.c only into the daemon.
// libntp/wscript builds libntpc from separate FFI/support sources. Keep this
// predicate closed over the reviewed Debian payload, including Python files;
// absence of a process or a filename alone would not prove parser absence.
func proveNTPQueryClient(bundle string, owned []string, elfs map[string]diagnosticELF) error {
	const python = "./python/lib/python3/dist-packages/"
	const library = python + "ntp/libntpc.so"
	allowed := map[string]bool{"./libexec/ntpq": true, library: true, python + "ntp-1.2.2.egg-info": true}
	for _, module := range []string{"__init__", "agentx", "agentx_packet", "control", "magic", "ntpc", "packet", "poly", "statfiles", "util"} {
		allowed[python+"ntp/"+module+".py"] = true
		allowed[python+"ntp/__pycache__/"+module+".cpython-311.pyc"] = true
	}
	for _, path := range owned {
		if !allowed[path] {
			return fmt.Errorf("unexpected NTPsec client file: %s", path)
		}
		info, err := os.Lstat(filepath.Join(bundle, path))
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("NTPsec client file is missing or not regular: %s", path)
		}
		if _, native := elfs[path]; native && path != library {
			return fmt.Errorf("unexpected native NTPsec payload: %s", path)
		}
	}
	client, err := os.ReadFile(filepath.Join(bundle, "libexec/ntpq"))
	if err != nil || !slices.Contains(owned, "./libexec/ntpq") || !strings.HasPrefix(string(client), "#! /usr/bin/python3\n") {
		return fmt.Errorf("NTPsec query client is not the reviewed Python entry point")
	}
	file, exists := elfs[library]
	if !slices.Contains(owned, library) || !exists || file.Class != elf.ELFCLASS64 || file.Machine != elf.EM_X86_64 {
		return fmt.Errorf("NTPsec helper is not inspectable native amd64 libntpc")
	}
	if !slices.ContainsFunc(file.Symbols, func(symbol elf.Symbol) bool { return symbol.Name == "ntpc_lfptofloat" }) {
		return fmt.Errorf("NTPsec helper lacks its reviewed FFI interface")
	}
	// Both hashes match the exact Debian package payload and the reviewed CI
	// bundle. A copied/renamed parser cannot gain approval by retaining a known
	// FFI symbol or the client's Python shebang under the same package identity.
	for path, expected := range map[string]string{
		"./libexec/ntpq": "b0cb0e98273e72575cb139a95719a15afad153a50749b653980850bb9161035a",
		library:          "61474fc2808110c2a0a791b89d04fd93471411536aab87ccb0cf4bd4a65d0681",
	} {
		actual, err := hashFile(filepath.Join(bundle, path))
		if err != nil || actual != expected {
			return fmt.Errorf("NTPsec assessment requires exact authenticated %s", path)
		}
	}
	// A renamed/copied implementation outside the assessed package also blocks.
	for path, file := range elfs {
		for _, symbol := range file.Symbols {
			if strings.HasPrefix(symbol.Name, "extens_") {
				return fmt.Errorf("NTPsec NTS implementation symbol in %s: %s", path, symbol.Name)
			}
		}
	}
	return filepath.WalkDir(bundle, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := entry.Name()
		if name == "ntpd" || strings.HasPrefix(name, "libntpd") || strings.HasPrefix(name, "nts_extens.") {
			return fmt.Errorf("NTPsec daemon implementation present: %s", path)
		}
		return nil
	})
}

func provePrivatePython(bundle string) error {
	type identity struct {
		ABI      json.RawMessage `json:"abi"`
		Builtins []string        `json:"builtins"`
	}
	read := func(name string) (identity, error) {
		var got identity
		data, err := os.ReadFile(filepath.Join(bundle, name))
		if err == nil {
			err = json.Unmarshal(data, &got)
		}
		return got, err
	}
	installed, err := read("python-installed-identity.json")
	if err != nil {
		return err
	}
	private, err := read("python-private-identity.json")
	if err != nil {
		return err
	}
	var want []string
	for _, name := range installed.Builtins {
		if name != "pyexpat" && name != "_elementtree" {
			want = append(want, name)
		}
	}
	if len(installed.ABI) == 0 || !reflect.DeepEqual(installed.ABI, private.ABI) || len(installed.Builtins) != len(private.Builtins)+2 || !slices.Equal(want, private.Builtins) {
		return fmt.Errorf("private Python ABI/builtins evidence differs")
	}
	source, err := os.ReadFile(filepath.Join(bundle, "source-builds.tsv"))
	if err != nil {
		return err
	}
	if !strings.Contains(string(source), "python3.11\t3.11.2-6+deb12u9\tDebian-signed-source; dsc_sha256=49c0d6e1f0d3aeef542de2e908da11bcbcb9343654fb70b51fe4f80865c9dc92;") {
		return fmt.Errorf("private Python does not use reviewed signed source")
	}
	return nil
}

func proveReadOnlyFindmnt(bundle string, elfs map[string]diagnosticELF) error {
	for path, expected := range map[string]string{
		"./libexec/findmnt":   "c20246863774b36e928b0447bd255fac51925d60c123ac187b7c1a5ccf8f3eb3",
		"./lib/libmount.so.1": "70c1da7f7a3d802c498f4938449bfc7a51877c46b16572d1a396901c032758bc",
	} {
		actual, err := hashFile(filepath.Join(bundle, path))
		if err != nil || actual != expected {
			return fmt.Errorf("libmount assessment requires exact authenticated %s", path)
		}
	}
	for path, file := range elfs {
		if slices.Contains(file.Libraries, "libmount.so.1") && path != "./libexec/findmnt" {
			return fmt.Errorf("unknown libmount consumer: %s", path)
		}
		if path != "./lib/libmount.so.1" && path != "./libexec/findmnt" {
			for _, symbol := range file.Symbols {
				if strings.HasPrefix(symbol.Name, "mnt_") {
					return fmt.Errorf("unexpected embedded/dynamic libmount consumer: %s", path)
				}
			}
		}
	}
	findmnt, exists := elfs["./libexec/findmnt"]
	if !exists {
		return fmt.Errorf("findmnt is not inspectable ELF")
	}
	libraries := slices.Clone(findmnt.Libraries)
	slices.Sort(libraries)
	if hashLines(libraries) != "d4fa2a0895ddb635ab16feb84820a04fe00f26f7ed33701ca5ca10721f423ecb" {
		return fmt.Errorf("findmnt linkage changed")
	}
	imports := map[string]bool{}
	for _, symbol := range findmnt.Symbols {
		if symbol.Section == elf.SHN_UNDEF && strings.HasPrefix(symbol.Name, "mnt_") {
			imports[symbol.Name] = true
		}
	}
	var names []string
	for name := range imports {
		names = append(names, name)
	}
	slices.Sort(names)
	if len(names) != 67 || hashLines(names) != "1e2d7d3be03314768421c7db0184dd30eb14b4580e2945b7431bf8a129b6d09d" {
		return fmt.Errorf("findmnt read-only imported API set changed")
	}
	return nil
}

func hashLines(lines []string) string {
	hash := sha256.Sum256([]byte(strings.Join(lines, "\n") + "\n"))
	return hex.EncodeToString(hash[:])
}
