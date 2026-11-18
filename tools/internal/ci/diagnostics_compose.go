package ci

import (
	"debug/buildinfo"
	"debug/elf"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const composeSourceURL = "https://codeload.github.com/docker/compose/tar.gz/5bceecf985347fcf6dd23029ce440b502a0d4301"
const composeToolchain = "go1.27.3"
const composeCompilerImage = "golang:1.27.3-alpine3.24@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18"

var composeBuildInputs = []string{
	"source_url=" + composeSourceURL,
	"source_sha256=f21c00230b32c4b01dcf516e37a195f166798443eaadfbdd635d86079f16fcb9",
	"source_commit=5bceecf985347fcf6dd23029ce440b502a0d4301",
	"toolchain_image=" + composeCompilerImage,
	"toolchain_version=" + composeToolchain,
	"go_mod_sha256=add1d3fc58082dc40ea0ebcc3d2c80b1f4bf99a5452aab2026e8997b511cfb09",
	"go_sum_sha256=742b5078110f95e2a78eb36cc17c13b340111297d574f140e7134c341bf0e3b2",
	"module_update=go get golang.org/x/net@v0.62.0",
	"module_update_advisories=CVE-2026-78661 / GO-2026-6860",
	"derived_go_mod_sha256=3f1cbe9c14f71355628c968b58f064d0ff81201b8637ca0389c9c7f746244b74",
	"derived_go_sum_sha256=3b18e947c444627b533d810db6fd0cf1a9d153c3e36a43bf15bb6169d9cf9a2b",
	"build_flags=GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -mod=readonly -trimpath -tags=e2e -ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.7.0",
}

// Inspect the final bytes, not a version printed by an executable or a claim
// in provenance. Source/compiler evidence is separately bound into the SBOM.
func diagnosticsComposeComponent(bundle string) (sbomComponent, error) {
	binary := filepath.Join(bundle, "cli-plugins/docker-compose")
	binaryHash, err := hashFile(binary)
	if err != nil {
		return sbomComponent{}, err
	}
	infoHash, err := hashFile(filepath.Join(bundle, "compose-buildinfo.txt"))
	if err != nil {
		return sbomComponent{}, err
	}
	evidence, err := os.ReadFile(filepath.Join(bundle, "compose-build.txt"))
	if err != nil {
		return sbomComponent{}, err
	}
	expected := strings.Join(composeBuildInputs, "\n") + "\nbinary_sha256=" + binaryHash + "\nbuild_info_sha256=" + infoHash + "\n"
	if string(evidence) != expected {
		return sbomComponent{}, fmt.Errorf("compose source/compiler/output evidence differs from final bytes")
	}
	info, err := buildinfo.ReadFile(binary)
	if err != nil {
		return sbomComponent{}, fmt.Errorf("inspect rebuilt Compose Go identity: %w", err)
	}
	if info.GoVersion != composeToolchain || info.Path != "github.com/docker/compose/v5/cmd" || info.Main.Path != "github.com/docker/compose/v5" {
		return sbomComponent{}, fmt.Errorf("compose binary has a different compiler or main module")
	}
	settings := map[string]string{}
	for _, setting := range info.Settings {
		settings[setting.Key] = setting.Value
	}
	for key, expected := range map[string]string{
		"CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "amd64", "-trimpath": "true", "-tags": "e2e",
	} {
		if settings[key] != expected {
			return sbomComponent{}, fmt.Errorf("compose binary build setting differs: %s", key)
		}
	}
	// Go omits -ldflags under -trimpath. The authenticated build recipe binds
	// them; inspectable symbols below and real version checks qualify the result.
	file, err := elf.Open(binary)
	if err != nil {
		return sbomComponent{}, err
	}
	defer file.Close()
	imports, err := file.ImportedLibraries()
	if err != nil {
		return sbomComponent{}, err
	}
	symbols, err := file.Symbols()
	if err != nil || len(symbols) == 0 || len(imports) != 0 || file.Class != elf.ELFCLASS64 || file.Machine != elf.EM_X86_64 {
		return sbomComponent{}, fmt.Errorf("compose must be inspectable static Linux amd64 ELF")
	}
	for _, program := range file.Progs {
		if program.Type == elf.PT_INTERP {
			return sbomComponent{}, fmt.Errorf("compose unexpectedly requires a host ELF interpreter")
		}
	}
	return sbomComponent{Reference: "docker-compose-v5.7.0", Type: "application", Name: "docker-compose", Version: "5.7.0", PURL: "pkg:github/docker/compose@v5.7.0",
		Properties: []sbomProperty{{"emisar:binary-sha256", binaryHash}, {"emisar:source-url", composeSourceURL}, {"emisar:go-toolchain", info.GoVersion}}}, nil
}
