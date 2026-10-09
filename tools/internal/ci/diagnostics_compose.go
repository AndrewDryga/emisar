package ci

import (
	"debug/buildinfo"
	"debug/elf"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const composeSourceURL = "https://codeload.github.com/docker/compose/tar.gz/5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de"
const composeToolchain = "go1.27.2"
const composeCompilerImage = "golang:1.27.2-alpine3.24@sha256:85dc1069ac644ea3c527b177303a406eb3358192816cd7f9e5848eb658851673"

var composeBuildInputs = []string{
	"source_url=" + composeSourceURL,
	"source_sha256=c72877db37172d8ee55f565e4fed20067af89015e986b190768fd4ee621025f2",
	"source_commit=5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de",
	"toolchain_image=" + composeCompilerImage,
	"toolchain_version=" + composeToolchain,
	"go_mod_sha256=cdf5424bec2a7c75fa955a56efc88fb1731db5cca019cf63d4a1980a218e0868",
	"go_sum_sha256=8e96090883306abcd19ed57025a3e108b0b1cf6a6dff220c73d1aa77bb408a10",
	"build_flags=GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -mod=readonly -trimpath -tags=e2e -ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.5.1",
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
	return sbomComponent{Reference: "docker-compose-v5.5.1", Type: "application", Name: "docker-compose", Version: "5.5.1", PURL: "pkg:github/docker/compose@v5.5.1",
		Properties: []sbomProperty{{"emisar:binary-sha256", binaryHash}, {"emisar:source-url", composeSourceURL}, {"emisar:go-toolchain", info.GoVersion}}}, nil
}
