package ci

import (
	"bufio"
	"context"
	"crypto/rand"
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
		if err := verifyDiagnosticsSBOM(sbom, actual, bundle); err != nil {
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
	Format       string `json:"bomFormat"`
	SerialNumber string `json:"serialNumber,omitempty"`
	Spec         string `json:"specVersion"`
	Version      int    `json:"version"`
	Metadata     struct {
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
		Properties: []sbomProperty{{"emisar:inventory-scope", "measured shipped Debian file closure"},
			{"aquasecurity:trivy:SrcName", fields[3]}, {"aquasecurity:trivy:SrcVersion", upstream},
			{"aquasecurity:trivy:SrcEpoch", epoch}, {"aquasecurity:trivy:SrcRelease", release}}}, nil
}

var diagnosticsEvidenceFiles = []string{"manifest", "SHA256SUMS", "file-origins.tsv", "debian-runtime.tsv", "debian-builder.tsv", "source-builds.tsv", "python-installed-identity.json", "python-private-identity.json", "python-private-build.txt", "compose-build.txt", "compose-buildinfo.txt"}

// DiagnosticsSBOM declares only measured shipped packages as runtime components.
// The complete builder inventory remains independently inspectable provenance,
// with exact file origins and manifests, never mislabeled as runtime packages.
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
	return writeDiagnosticsSBOM(bundle, revision, identity.ID, runtimeSBOM, destination)
}

func writeDiagnosticsSBOM(bundle, revision, imageID, runtimeSBOM, destination string) error {
	manifestHash, err := hashFile(filepath.Join(bundle, "manifest"))
	if err != nil {
		return err
	}
	var serial [16]byte
	if _, err := rand.Read(serial[:]); err != nil {
		return fmt.Errorf("generate diagnostics SBOM serial number: %w", err)
	}
	serial[6] = serial[6]&0x0f | 0x40
	serial[8] = serial[8]&0x3f | 0x80
	sbom := diagnosticSBOM{Format: "CycloneDX", Spec: "1.6", Version: 1,
		SerialNumber: fmt.Sprintf("urn:uuid:%x-%x-%x-%x-%x", serial[:4], serial[4:6], serial[6:8], serial[8:10], serial[10:])}
	sbom.Metadata.Properties = []sbomProperty{{"emisar:purpose", "admin-diagnostics"}, {"emisar:revision", revision}, {"emisar:architecture", "amd64"}, {"emisar:image-id", imageID}, {"emisar:bundle-manifest-sha256", manifestHash}, {"emisar:inventory-scope", "measured shipped Debian closure; complete builder provenance retained"}}
	for _, name := range diagnosticsEvidenceFiles {
		data, err := os.ReadFile(filepath.Join(bundle, name))
		if err != nil {
			return fmt.Errorf("missing diagnostics evidence %s: %w", name, err)
		}
		if len(data) == 0 {
			return fmt.Errorf("empty diagnostics evidence %s", name)
		}
		hash := sha256.Sum256(data)
		sbom.Metadata.Properties = append(sbom.Metadata.Properties,
			sbomProperty{"emisar:evidence:" + name, string(data)},
			sbomProperty{"emisar:evidence-sha256:" + name, hex.EncodeToString(hash[:])})
	}
	components, err := diagnosticsDebianComponents(bundle)
	if err != nil {
		return err
	}
	sbom.Components = components
	source, err := os.ReadFile(filepath.Join(bundle, "source-builds.tsv"))
	if err != nil {
		return err
	}
	sbom.Metadata.Properties = append(sbom.Metadata.Properties, sbomProperty{"emisar:source-builds", string(source)})
	compose, err := diagnosticsComposeComponent(bundle)
	if err != nil {
		return err
	}
	sbom.Components = append(sbom.Components, sbomComponent{Reference: "debian-12", Type: "operating-system", Name: "debian", Version: "12"}, compose)
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
	var encodedComponents []json.RawMessage
	if err := json.Unmarshal(document["components"], &encodedComponents); err != nil {
		return err
	}
	document["components"], err = json.Marshal(append(encodedComponents, runtimeComponents...))
	if err != nil {
		return err
	}
	data, err = json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(destination, append(data, '\n'), 0o600)
}

func diagnosticsDebianComponents(bundle string) ([]sbomComponent, error) {
	origins, err := readDiagnosticsOrigins(bundle)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(filepath.Join(bundle, "debian-runtime.tsv"))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var components []sbomComponent
	seen := map[string]bool{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		row := scanner.Text()
		component, err := debianInventoryComponent(row)
		if err != nil {
			return nil, err
		}
		if len(origins[row]) == 0 {
			return nil, fmt.Errorf("runtime package has no shipped file origin: %s", component.Name)
		}
		if seen[component.PURL] {
			return nil, fmt.Errorf("duplicate runtime package: %s", component.Name)
		}
		seen[component.PURL] = true
		component.Properties = append(component.Properties, sbomProperty{"emisar:runtime-file-origins", strings.Join(origins[row], "\n")})
		components = append(components, component)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(components) == 0 || len(seen) != len(origins) {
		return nil, fmt.Errorf("runtime inventory does not cover every Debian file owner")
	}
	return components, nil
}

func readDiagnosticsOrigins(bundle string) (map[string][]string, error) {
	data, err := os.ReadFile(filepath.Join(bundle, "file-origins.tsv"))
	if err != nil {
		return nil, err
	}
	origins := map[string][]string{}
	seen := map[string]bool{}
	for _, row := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		fields := strings.Split(row, "\t")
		if len(fields) != 8 || seen[fields[0]] {
			return nil, fmt.Errorf("invalid or duplicate diagnostics file origin")
		}
		for _, field := range fields {
			if field == "" {
				return nil, fmt.Errorf("incomplete diagnostics file origin")
			}
		}
		seen[fields[0]] = true
		switch fields[1] {
		case "debian", "debian-source", "debian-extracted", "debian-bytecode":
			identity := strings.Join(fields[3:], "\t")
			origins[identity] = append(origins[identity], strings.Join(fields[:3], "\t"))
		case "repository":
		case "github-source":
			if (fields[0] != "./cli-plugins/docker-compose" && fields[0] != "./compose/LICENSE" && fields[0] != "./compose/NOTICE") ||
				fields[2] != composeSourceURL || strings.Join(fields[3:], "\t") != "docker-compose\t5.5.1\tamd64\tdocker/compose\tv5.5.1" {
				return nil, fmt.Errorf("unexpected Compose source origin")
			}
		case "compiler-image":
			if fields[0] != "./compose/GO-LICENSE" || fields[2] != composeCompilerImage || strings.Join(fields[3:], "\t") != "stdlib\tv1.27.2\tall\tgolang/go\tgo1.27.2" {
				return nil, fmt.Errorf("unexpected Go runtime license origin")
			}
		default:
			return nil, fmt.Errorf("unknown diagnostics file origin: %s", fields[1])
		}
	}
	return origins, nil
}

func verifyDiagnosticsSBOM(path string, contract imageContract, bundle string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var sbom diagnosticSBOM
	if err := json.Unmarshal(data, &sbom); err != nil {
		return err
	}
	if sbom.Format != "CycloneDX" || sbom.Spec != "1.6" || sbom.Version != 1 ||
		!regexp.MustCompile(`^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(sbom.SerialNumber) {
		return fmt.Errorf("diagnostics SBOM requires CycloneDX 1.6 version 1 and an RFC 4122 UUIDv4 serial number")
	}
	properties := map[string]string{}
	for _, property := range sbom.Metadata.Properties {
		if _, exists := properties[property.Name]; exists {
			return fmt.Errorf("duplicate diagnostics SBOM metadata: %s", property.Name)
		}
		properties[property.Name] = property.Value
	}
	if len(sbom.Components) == 0 ||
		properties["emisar:purpose"] != contract.Purpose ||
		properties["emisar:revision"] != contract.Revision ||
		properties["emisar:architecture"] != contract.Architecture ||
		properties["emisar:image-id"] != contract.ImageID ||
		properties["emisar:bundle-manifest-sha256"] != contract.BundleManifestHash ||
		properties["emisar:inventory-scope"] != "measured shipped Debian closure; complete builder provenance retained" ||
		!strings.Contains(properties["emisar:source-builds"], "sysstat\t") ||
		!strings.Contains(properties["emisar:source-builds"], "python3.11\t") {
		return fmt.Errorf("diagnostics SBOM is not bound to the tested image and bundle manifest")
	}
	for _, name := range diagnosticsEvidenceFiles {
		actual, err := os.ReadFile(filepath.Join(bundle, name))
		if err != nil {
			return fmt.Errorf("missing bound diagnostics evidence %s: %w", name, err)
		}
		if len(actual) == 0 {
			return fmt.Errorf("empty bound diagnostics evidence %s", name)
		}
		hash := sha256.Sum256(actual)
		if properties["emisar:evidence:"+name] != string(actual) || properties["emisar:evidence-sha256:"+name] != hex.EncodeToString(hash[:]) {
			return fmt.Errorf("diagnostics SBOM evidence does not match final bundle: %s", name)
		}
	}
	expected, err := diagnosticsDebianComponents(bundle)
	if err != nil {
		return err
	}
	actual := map[string]sbomComponent{}
	for _, component := range sbom.Components {
		if strings.HasPrefix(component.PURL, "pkg:deb/") {
			if _, exists := actual[component.PURL]; exists {
				return fmt.Errorf("duplicate Debian runtime SBOM component")
			}
			actual[component.PURL] = component
		}
	}
	if len(actual) != len(expected) {
		return fmt.Errorf("sbom Debian components differ from measured runtime inventory")
	}
	for _, component := range expected {
		got, exists := actual[component.PURL]
		wantJSON, _ := json.Marshal(component)
		gotJSON, _ := json.Marshal(got)
		if !exists || string(wantJSON) != string(gotJSON) {
			return fmt.Errorf("sbom runtime ownership/source differs from final bundle: %s", component.Name)
		}
	}
	compose, err := diagnosticsComposeComponent(bundle)
	if err != nil {
		return err
	}
	composeCount, toolchainCount := 0, 0
	for _, component := range sbom.Components {
		if component.Reference == compose.Reference || component.PURL == compose.PURL {
			wantJSON, _ := json.Marshal(compose)
			gotJSON, _ := json.Marshal(component)
			if string(wantJSON) != string(gotJSON) {
				return fmt.Errorf("sbom Compose identity differs from source-built bytes")
			}
			composeCount++
		}
		if component.PURL == "pkg:golang/stdlib@v1.27.2" && component.Name == "stdlib" && component.Version == "v1.27.2" {
			toolchainCount++
		}
	}
	if composeCount != 1 || toolchainCount != 1 {
		return fmt.Errorf("sbom omits or duplicates rebuilt Compose/patched Go runtime")
	}
	return nil
}
