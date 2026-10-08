package ci

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/toolutil"
)

type imageIdentity struct {
	ID           string `json:"Id"`
	OS           string `json:"Os"`
	Architecture string
	Config       struct{ Labels map[string]string }
}

type imageContract struct {
	Schema             int    `json:"schema"`
	Purpose            string `json:"purpose"`
	Revision           string `json:"revision"`
	OS                 string `json:"os"`
	Architecture       string `json:"architecture"`
	ImageID            string `json:"image_id"`
	ArchiveSHA256      string `json:"archive_sha256"`
	SBOMSHA256         string `json:"sbom_sha256"`
	BundleManifestHash string `json:"bundle_manifest_sha256,omitempty"`
}

func validateImageIdentity(identity imageIdentity, purpose, revision string) error {
	if purpose != "portal" && purpose != "admin-diagnostics" {
		return fmt.Errorf("unknown image purpose %q", purpose)
	}
	if !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(revision) ||
		identity.OS != "linux" || identity.Architecture != "amd64" ||
		!regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(identity.ID) ||
		identity.Config.Labels["org.emisar.image-purpose"] != purpose ||
		identity.Config.Labels["org.opencontainers.image.revision"] != revision {
		return fmt.Errorf("image does not match required purpose=%s revision=%s linux/amd64 identity", purpose, revision)
	}
	return nil
}

func inspectImage(ctx context.Context, image string) (imageIdentity, error) {
	var identity imageIdentity
	runner := toolutil.Runner{}
	data, err := runner.Output(ctx, "", nil, "docker", "inspect", "--format", "{{json .}}", image)
	if err != nil {
		return identity, err
	}
	err = json.Unmarshal(data, &identity)
	return identity, err
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	count, err := io.Copy(hash, file)
	if err != nil {
		return "", err
	}
	if count == 0 {
		return "", fmt.Errorf("empty artifact: %s", path)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// extractDiagnostics never starts the extraction container. Its validator is
// repository-owned code, not an executable supplied by the artifact.
func extractDiagnostics(ctx context.Context, root, image, revision string) (string, func(), error) {
	temp, err := os.MkdirTemp("", "emisar-diagnostics-contract-")
	if err != nil {
		return "", nil, err
	}
	runner := toolutil.Runner{}
	cid := ""
	cleanup := func() {
		if cid != "" {
			_, _ = runner.Output(context.Background(), "", nil, "docker", "rm", cid)
		}
		_ = os.RemoveAll(temp)
	}
	data, err := runner.Output(ctx, root, nil, "docker", "create", "--network", "none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", image)
	if err == nil {
		cid = strings.TrimSpace(string(data))
		_, err = runner.Output(ctx, root, nil, "docker", "cp", cid+":/bundle", filepath.Join(temp, "bundle"))
	}
	bundle := filepath.Join(temp, "bundle")
	if err == nil {
		_, err = runner.Output(ctx, root, nil, "bash", filepath.Join(root, "infra/runtime/admin-runner/verify-diagnostics.sh"), bundle, revision, "amd64")
	}
	if err != nil {
		cleanup()
		return "", nil, fmt.Errorf("diagnostics artifact contract: %w", err)
	}
	return bundle, cleanup, nil
}

// ImageContract binds the exact tested image config, export and SBOM bytes.
// Both CD publication and planning verify the same contract; neither rebuilds.
func ImageContract(ctx context.Context, root, mode, purpose, revision, image, archive, sbom, path string) error {
	identity, err := inspectImage(ctx, image)
	if err != nil {
		return err
	}
	if err := validateImageIdentity(identity, purpose, revision); err != nil {
		return err
	}
	actual := imageContract{Schema: 1, Purpose: purpose, Revision: revision, OS: identity.OS, Architecture: identity.Architecture, ImageID: identity.ID}
	if actual.ArchiveSHA256, err = hashFile(archive); err != nil {
		return err
	}
	if actual.SBOMSHA256, err = hashFile(sbom); err != nil {
		return err
	}
	if purpose == "admin-diagnostics" {
		bundle, cleanup, err := extractDiagnostics(ctx, root, image, revision)
		if err != nil {
			return err
		}
		defer cleanup()
		if actual.BundleManifestHash, err = hashFile(filepath.Join(bundle, "manifest")); err != nil {
			return err
		}
		if err := verifyDiagnosticsSBOM(sbom, actual); err != nil {
			return err
		}
	}
	switch mode {
	case "create":
		data, err := json.MarshalIndent(actual, "", "  ")
		if err != nil {
			return err
		}
		return os.WriteFile(path, append(data, '\n'), 0o600)
	case "verify":
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		var expected imageContract
		decoder := json.NewDecoder(file)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&expected); err != nil {
			return err
		}
		if err := decoder.Decode(new(any)); err != io.EOF {
			return fmt.Errorf("trailing image contract content")
		}
		if expected != actual {
			return fmt.Errorf("tested image/export/SBOM contract mismatch for %s", purpose)
		}
		return nil
	default:
		return fmt.Errorf("image-contract mode must be create or verify")
	}
}

type sbomProperty struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type sbomComponent struct {
	Reference  string         `json:"bom-ref"`
	Type       string         `json:"type"`
	Name       string         `json:"name"`
	Version    string         `json:"version"`
	PURL       string         `json:"purl,omitempty"`
	Properties []sbomProperty `json:"properties,omitempty"`
}

type diagnosticSBOM struct {
	Format   string `json:"bomFormat"`
	Spec     string `json:"specVersion"`
	Version  int    `json:"version"`
	Metadata struct {
		Properties []sbomProperty `json:"properties"`
	} `json:"metadata"`
	Components []sbomComponent `json:"components"`
}

func debianInventoryComponent(line string) (sbomComponent, error) {
	fields := strings.Split(line, "\t")
	if len(fields) != 5 {
		return sbomComponent{}, fmt.Errorf("malformed signed Debian inventory row: %q", line)
	}
	for _, field := range fields {
		if field == "" {
			return sbomComponent{}, fmt.Errorf("incomplete signed Debian inventory row: %q", line)
		}
	}
	epoch, upstream := "0", fields[4]
	if before, after, found := strings.Cut(upstream, ":"); found {
		epoch, upstream = before, after
	}
	if !regexp.MustCompile(`^[0-9]+$`).MatchString(epoch) {
		return sbomComponent{}, fmt.Errorf("invalid Debian source epoch: %q", epoch)
	}
	release := "0"
	if index := strings.LastIndex(upstream, "-"); index >= 0 {
		upstream, release = upstream[:index], upstream[index+1:]
	}
	purl := "pkg:deb/debian/" + fields[0] + "@" + url.QueryEscape(fields[1]) + "?arch=" + fields[2] + "&distro=debian-12"
	return sbomComponent{Reference: purl, Type: "library", Name: fields[0], Version: fields[1], PURL: purl,
		Properties: []sbomProperty{{"emisar:inventory-scope", "conservative builder inventory; may be build-only"},
			{"aquasecurity:trivy:SrcName", fields[3]}, {"aquasecurity:trivy:SrcVersion", upstream},
			{"aquasecurity:trivy:SrcEpoch", epoch}, {"aquasecurity:trivy:SrcRelease", release}}}, nil
}

// DiagnosticsSBOM records conservative signed Debian builder inventory, rather
// than silently treating stripped scratch bytes as having no OS components.
// Build-only packages are explicitly labeled; downloaded ntpsec and the rebuilt
// sysstat source identity are retained, along with the exact final file manifest.
func DiagnosticsSBOM(ctx context.Context, root, revision, image, runtimeSBOM, destination string) error {
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
	sbom := diagnosticSBOM{Format: "CycloneDX", Spec: "1.6", Version: 1}
	sbom.Metadata.Properties = []sbomProperty{{"emisar:purpose", "admin-diagnostics"}, {"emisar:revision", revision}, {"emisar:architecture", "amd64"}, {"emisar:image-id", identity.ID}, {"emisar:bundle-manifest-sha256", manifestHash}, {"emisar:inventory-scope", "conservative signed Debian builder inventory, including build-only packages"}}
	file, err := os.Open(filepath.Join(bundle, "debian-inventory.tsv"))
	if err != nil {
		return err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		component, err := debianInventoryComponent(scanner.Text())
		if err != nil {
			return err
		}
		sbom.Components = append(sbom.Components, component)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	source, err := os.ReadFile(filepath.Join(bundle, "source-builds.tsv"))
	if err != nil {
		return err
	}
	sbom.Metadata.Properties = append(sbom.Metadata.Properties, sbomProperty{"emisar:source-builds", string(source)})
	sbom.Components = append(sbom.Components, sbomComponent{Reference: "debian-12", Type: "operating-system", Name: "debian", Version: "12"},
		sbomComponent{Reference: "docker-compose-v5.5.1", Type: "application", Name: "docker-compose", Version: "5.5.1", PURL: "pkg:github/docker/compose@v5.5.1", Properties: []sbomProperty{{"emisar:binary-sha256", "db1889184726840f75c4f9c001048430d4f25b3be3cb084d3ddd762bc0aed576"}}})
	// Preserve Trivy's exact Go/Python component metadata, licenses and hashes.
	runtimeData, err := os.ReadFile(runtimeSBOM)
	if err != nil {
		return err
	}
	var runtimeDocument map[string]json.RawMessage
	if err := json.Unmarshal(runtimeData, &runtimeDocument); err != nil {
		return err
	}
	var runtimeComponents []json.RawMessage
	if err := json.Unmarshal(runtimeDocument["components"], &runtimeComponents); err != nil {
		return err
	}
	data, err := json.Marshal(sbom)
	if err != nil {
		return err
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(data, &document); err != nil {
		return err
	}
	var components []json.RawMessage
	if err := json.Unmarshal(document["components"], &components); err != nil {
		return err
	}
	document["components"], err = json.Marshal(append(components, runtimeComponents...))
	if err != nil {
		return err
	}
	data, err = json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(destination, append(data, '\n'), 0o600)
}

func verifyDiagnosticsSBOM(path string, contract imageContract) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var sbom diagnosticSBOM
	if err := json.Unmarshal(data, &sbom); err != nil {
		return err
	}
	properties := map[string]string{}
	for _, property := range sbom.Metadata.Properties {
		properties[property.Name] = property.Value
	}
	if sbom.Format != "CycloneDX" || len(sbom.Components) == 0 ||
		properties["emisar:purpose"] != contract.Purpose ||
		properties["emisar:revision"] != contract.Revision ||
		properties["emisar:architecture"] != contract.Architecture ||
		properties["emisar:image-id"] != contract.ImageID ||
		properties["emisar:bundle-manifest-sha256"] != contract.BundleManifestHash ||
		!strings.Contains(properties["emisar:source-builds"], "sysstat\t") {
		return fmt.Errorf("diagnostics SBOM is not bound to the tested image and bundle manifest")
	}
	return nil
}
