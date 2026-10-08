package ci

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

// VerifyDebianDecoder exercises the pinned Trivy CLI's real source identity
// decoder without an advisory DB. Kept in the explicit image qualifier lane,
// not the Docker/feed-free canonical Go gate.
func VerifyDebianDecoder(ctx context.Context) error {
	temp, err := os.MkdirTemp("", "emisar-trivy-debian-decoder-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	rows := []string{
		"libc6\t2.36-9+deb12u13\tamd64\tglibc\t2.36-9+deb12u13",
		"libssl3\t3.0.17-1~deb12u2\tamd64\topenssl\t3.0.17-1~deb12u2",
		"libexample1\t1:2.3-4+b2\tamd64\texample\t1:2.3-4",
	}
	runner := toolutil.Runner{}
	for _, includeSource := range []bool{true, false} {
		sbom := diagnosticSBOM{Format: "CycloneDX", Spec: "1.6", Version: 1}
		sbom.Components = append(sbom.Components, sbomComponent{Reference: "debian-12", Type: "operating-system", Name: "debian", Version: "12"})
		for _, row := range rows {
			component, err := debianInventoryComponent(row)
			if err != nil {
				return err
			}
			if !includeSource {
				component.Properties = nil
			}
			sbom.Components = append(sbom.Components, component)
		}
		data, err := json.Marshal(sbom)
		if err != nil {
			return err
		}
		input, output := filepath.Join(temp, "fixture.cdx.json"), filepath.Join(temp, "decoded.json")
		if err := os.WriteFile(input, data, 0o600); err != nil {
			return err
		}
		if _, err := runner.Output(ctx, "", nil, "trivy", "sbom", "--scanners", "license", "--format", "json", "--list-all-pkgs", "--output", output, input); err != nil {
			return err
		}
		data, err = os.ReadFile(output)
		if err != nil {
			return err
		}
		var report struct {
			Results []struct {
				Type     string
				Packages []struct {
					Name, Version, SrcName, SrcVersion, SrcRelease string
					SrcEpoch                                       int
				}
			}
		}
		if err := json.Unmarshal(data, &report); err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, result := range report.Results {
			if result.Type != "debian" {
				continue
			}
			for _, pkg := range result.Packages {
				seen[pkg.Name] = true
				want := map[string]string{"libc6": "glibc", "libssl3": "openssl", "libexample1": "example"}[pkg.Name]
				if !includeSource {
					want = pkg.Name
				}
				if pkg.SrcName != want {
					return fmt.Errorf("trivy did not decode source identity for %s: got %s want %s", pkg.Name, pkg.SrcName, want)
				}
				if pkg.Name == "libexample1" && includeSource && (pkg.SrcEpoch != 1 || pkg.SrcVersion != "2.3" || pkg.SrcRelease != "4" || !strings.Contains(pkg.Version, "+b2")) {
					return fmt.Errorf("trivy lost binNMU/epoch/source revision: %+v", pkg)
				}
			}
		}
		if !seen["libc6"] || !seen["libssl3"] || !seen["libexample1"] {
			return fmt.Errorf("trivy decoder produced no complete Debian package target: %v", seen)
		}
	}
	return nil
}
