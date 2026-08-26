// Command releasepublish publishes runner and MCP release archives to the
// GCS-backed Emisar release mirror. Versioned objects are create-only; the
// latest pointer advances monotonically after every referenced object exists.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	defaultEndpoint          = "https://storage.googleapis.com"
	maxObjectBytes           = 256 << 20
	maxAttestationBundleSize = 4 << 20
)

var errPrecondition = errors.New("object generation changed")

type options struct {
	dir            string
	bucket         string
	component      string
	tag            string
	sourceRevision string
	token          string
	endpoint       string
	client         *http.Client
	logf           func(string, ...any)
}

type releaseManifest struct {
	SchemaVersion  int        `json:"schema_version"`
	Component      string     `json:"component"`
	Tag            string     `json:"tag"`
	Version        string     `json:"version"`
	SourceRevision string     `json:"source_revision"`
	Artifacts      []artifact `json:"artifacts"`
}

type artifact struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
}

type object struct {
	name        string
	contentType string
	data        []byte
	immutable   bool
}

type semver struct {
	major int
	minor int
	patch int
}

func main() {
	var opts options
	flag.StringVar(&opts.dir, "dir", "", "directory containing assembled release assets")
	flag.StringVar(&opts.bucket, "bucket", "", "GCS bucket")
	flag.StringVar(&opts.component, "component", "", "release component: runner or mcp")
	flag.StringVar(&opts.tag, "tag", "", "release tag")
	flag.StringVar(&opts.sourceRevision, "source-revision", "", "release source commit SHA")
	flag.Parse()
	opts.token = os.Getenv("GOOGLE_OAUTH_ACCESS_TOKEN")
	opts.logf = func(format string, args ...any) { fmt.Printf(format+"\n", args...) }

	if err := publish(context.Background(), opts); err != nil {
		fmt.Fprintf(os.Stderr, "releasepublish: %v\n", err)
		os.Exit(1)
	}
}

func publish(ctx context.Context, opts options) error {
	version, err := validateOptions(opts)
	if err != nil {
		return err
	}
	if opts.endpoint == "" {
		opts.endpoint = defaultEndpoint
	}
	if opts.client == nil {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		opts.client = &http.Client{Transport: transport, Timeout: 5 * time.Minute}
	}
	if opts.logf == nil {
		opts.logf = func(string, ...any) {}
	}

	objects, manifest, err := buildObjects(opts, version)
	if err != nil {
		return err
	}
	for _, obj := range objects {
		uploaded, err := putObject(ctx, opts, obj, "0")
		if err != nil {
			return err
		}
		if uploaded {
			opts.logf("uploaded %s (%d bytes)", obj.name, len(obj.data))
		} else {
			opts.logf("skipped %s (already published, identical bytes)", obj.name)
		}
	}

	latest := object{
		name:        "releases/" + opts.component + "/latest.json",
		contentType: "application/json",
		data:        manifest,
	}
	return advanceLatest(ctx, opts, latest, version)
}

func validateOptions(opts options) (semver, error) {
	if opts.dir == "" || opts.bucket == "" || opts.component == "" || opts.tag == "" || opts.sourceRevision == "" {
		return semver{}, errors.New("--dir, --bucket, --component, --tag, and --source-revision are required")
	}
	if opts.token == "" {
		return semver{}, errors.New("GOOGLE_OAUTH_ACCESS_TOKEN is required")
	}
	prefix := opts.component + "-v"
	if opts.component == "runner" {
		prefix = "runner-v"
	} else if opts.component != "mcp" {
		return semver{}, fmt.Errorf("unsupported component %q", opts.component)
	}
	if !strings.HasPrefix(opts.tag, prefix) {
		return semver{}, fmt.Errorf("tag %q must start with %s", opts.tag, prefix)
	}
	version, err := parseSemver(strings.TrimPrefix(opts.tag, prefix))
	if err != nil {
		return semver{}, fmt.Errorf("invalid release tag %q: %w", opts.tag, err)
	}
	if matched, _ := regexp.MatchString(`^[0-9a-f]{40}$`, opts.sourceRevision); !matched {
		return semver{}, errors.New("source revision must be a 40-character lowercase Git commit SHA")
	}
	return version, nil
}

func buildObjects(opts options, version semver) ([]object, []byte, error) {
	versionText := version.String()
	archivePrefix := "emisar-"
	checksumName := "SHA256SUMS"
	if opts.component == "mcp" {
		archivePrefix = "emisar-mcp-"
		checksumName = "SHA256SUMS-MCP"
	}

	checksumsPath := filepath.Join(opts.dir, checksumName)
	checksums, err := os.ReadFile(checksumsPath)
	if err != nil {
		return nil, nil, fmt.Errorf("read %s: %w", checksumName, err)
	}
	wantNames := make([]string, 0, 6)
	for _, platform := range []string{"darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64"} {
		wantNames = append(wantNames, archivePrefix+versionText+"-"+platform+".tar.gz")
	}
	if opts.component == "mcp" {
		for _, platform := range []string{"windows-amd64", "windows-arm64"} {
			wantNames = append(wantNames, archivePrefix+versionText+"-"+platform+".zip")
		}
	}
	wantHashes, err := parseChecksums(checksums, wantNames)
	if err != nil {
		return nil, nil, err
	}

	base := "releases/" + opts.component + "/" + opts.tag + "/"
	objects := make([]object, 0, 10)
	artifacts := make([]artifact, 0, len(wantNames))
	for _, name := range wantNames {
		data, err := readBounded(filepath.Join(opts.dir, name), maxObjectBytes)
		if err != nil {
			return nil, nil, err
		}
		got := sha256Hex(data)
		if got != wantHashes[name] {
			return nil, nil, fmt.Errorf("%s digest is %s, %s says %s", name, got, checksumName, wantHashes[name])
		}
		sidecarName := name + ".sha256"
		sidecar, err := readBounded(filepath.Join(opts.dir, sidecarName), 1<<20)
		if err != nil {
			return nil, nil, err
		}
		if strings.TrimSpace(string(sidecar)) != got {
			return nil, nil, fmt.Errorf("%s does not match %s", sidecarName, name)
		}
		contentType := "application/gzip"
		if strings.HasSuffix(name, ".zip") {
			contentType = "application/zip"
		}
		objects = append(objects,
			object{name: base + name, contentType: contentType, data: data, immutable: true},
			object{name: base + sidecarName, contentType: "text/plain", data: sidecar, immutable: true},
		)
		artifacts = append(artifacts, artifact{Name: name, SHA256: got})
	}
	objects = append(objects, object{
		name:        base + checksumName,
		contentType: "text/plain",
		data:        checksums,
		immutable:   true,
	})
	bundleName := checksumName + ".sigstore.jsonl"
	bundle, err := readBounded(filepath.Join(opts.dir, bundleName), maxAttestationBundleSize)
	if err != nil {
		return nil, nil, err
	}
	if len(bundle) == 0 {
		return nil, nil, fmt.Errorf("%s is empty", bundleName)
	}
	objects = append(objects, object{
		name:        base + bundleName,
		contentType: "application/json",
		data:        bundle,
		immutable:   true,
	})
	manifest, err := json.MarshalIndent(releaseManifest{
		SchemaVersion:  1,
		Component:      opts.component,
		Tag:            opts.tag,
		Version:        versionText,
		SourceRevision: opts.sourceRevision,
		Artifacts:      artifacts,
	}, "", "  ")
	if err != nil {
		return nil, nil, fmt.Errorf("encode release manifest: %w", err)
	}
	manifest = append(manifest, '\n')
	objects = append(objects, object{
		name:        base + "manifest.json",
		contentType: "application/json",
		data:        manifest,
		immutable:   true,
	})
	return objects, manifest, nil
}

func parseChecksums(data []byte, wantNames []string) (map[string]string, error) {
	wanted := make(map[string]bool, len(wantNames))
	for _, name := range wantNames {
		wanted[name] = true
	}
	got := make(map[string]string, len(wantNames))
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || !wanted[fields[1]] {
			return nil, fmt.Errorf("unexpected checksum line %q", line)
		}
		if _, err := hex.DecodeString(fields[0]); err != nil || len(fields[0]) != 64 {
			return nil, fmt.Errorf("invalid sha256 for %s", fields[1])
		}
		if _, duplicate := got[fields[1]]; duplicate {
			return nil, fmt.Errorf("duplicate checksum for %s", fields[1])
		}
		got[fields[1]] = fields[0]
	}
	if len(got) != len(wantNames) {
		return nil, fmt.Errorf("checksum file covers %d artifacts, want %d", len(got), len(wantNames))
	}
	return got, nil
}

func advanceLatest(ctx context.Context, opts options, latest object, target semver) error {
	for range 5 {
		current, generation, found, err := getObject(ctx, opts, latest.name, maxObjectBytes)
		if err != nil {
			return fmt.Errorf("read current %s: %w", latest.name, err)
		}
		if found {
			var manifest releaseManifest
			if err := json.Unmarshal(current, &manifest); err != nil {
				return fmt.Errorf("parse current %s: %w", latest.name, err)
			}
			if manifest.SchemaVersion != 1 || manifest.Component != opts.component {
				return fmt.Errorf("current %s has an incompatible release manifest", latest.name)
			}
			currentVersion, err := parseSemver(manifest.Version)
			if err != nil {
				return fmt.Errorf("current %s has invalid version %q: %w", latest.name, manifest.Version, err)
			}
			switch compareSemver(currentVersion, target) {
			case 1:
				opts.logf("left %s at newer release %s", latest.name, manifest.Tag)
				return nil
			case 0:
				if !bytes.Equal(current, latest.data) {
					return fmt.Errorf("current %s has different bytes for release %s", latest.name, manifest.Tag)
				}
				opts.logf("skipped %s (already points at %s)", latest.name, manifest.Tag)
				return nil
			}
		} else {
			generation = "0"
		}

		uploaded, err := putObject(ctx, opts, latest, generation)
		if errors.Is(err, errPrecondition) {
			continue
		}
		if err != nil {
			return err
		}
		if !uploaded {
			return errors.New("latest pointer unexpectedly treated as immutable")
		}
		opts.logf("advanced %s to %s", latest.name, opts.tag)
		return nil
	}
	return fmt.Errorf("advance %s: generation changed too many times", latest.name)
}

func putObject(ctx context.Context, opts options, obj object, generation string) (bool, error) {
	query := url.Values{"uploadType": {"multipart"}, "ifGenerationMatch": {generation}}
	uploadURL := fmt.Sprintf("%s/upload/storage/v1/b/%s/o?%s",
		strings.TrimRight(opts.endpoint, "/"), url.PathEscape(opts.bucket), query.Encode())

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadataHeader := make(textproto.MIMEHeader)
	metadataHeader.Set("Content-Type", "application/json; charset=UTF-8")
	metadataPart, err := writer.CreatePart(metadataHeader)
	if err != nil {
		return false, fmt.Errorf("create metadata part for %s: %w", obj.name, err)
	}
	cacheControl := "no-store"
	if obj.immutable {
		cacheControl = "public, max-age=31536000, immutable"
	}
	metadata := struct {
		Name         string `json:"name"`
		ContentType  string `json:"contentType"`
		CacheControl string `json:"cacheControl"`
	}{obj.name, obj.contentType, cacheControl}
	if err := json.NewEncoder(metadataPart).Encode(metadata); err != nil {
		return false, fmt.Errorf("encode metadata for %s: %w", obj.name, err)
	}
	dataHeader := make(textproto.MIMEHeader)
	dataHeader.Set("Content-Type", obj.contentType)
	dataPart, err := writer.CreatePart(dataHeader)
	if err != nil {
		return false, fmt.Errorf("create data part for %s: %w", obj.name, err)
	}
	if _, err := dataPart.Write(obj.data); err != nil {
		return false, fmt.Errorf("encode data for %s: %w", obj.name, err)
	}
	if err := writer.Close(); err != nil {
		return false, fmt.Errorf("finish upload for %s: %w", obj.name, err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, &body)
	if err != nil {
		return false, fmt.Errorf("build upload request for %s: %w", obj.name, err)
	}
	req.Header.Set("Authorization", "Bearer "+opts.token)
	req.Header.Set("Content-Type", "multipart/related; boundary="+writer.Boundary())
	resp, err := opts.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("upload %s: %w", obj.name, err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return true, nil
	}
	if resp.StatusCode == http.StatusPreconditionFailed {
		if !obj.immutable {
			return false, errPrecondition
		}
		stored, _, found, err := getObject(ctx, opts, obj.name, len(obj.data))
		if err != nil {
			return false, fmt.Errorf("verify existing immutable object %s: %w", obj.name, err)
		}
		if !found || !bytes.Equal(stored, obj.data) {
			return false, fmt.Errorf("immutable object %s already exists with different bytes", obj.name)
		}
		return false, nil
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return false, fmt.Errorf("upload %s: HTTP %d; verify release-publisher federation and bucket access", obj.name, resp.StatusCode)
	}
	return false, fmt.Errorf("upload %s: HTTP %d: %s", obj.name, resp.StatusCode, string(responseBody))
}

func getObject(ctx context.Context, opts options, name string, maxBytes int) ([]byte, string, bool, error) {
	base := fmt.Sprintf("%s/storage/v1/b/%s/o/%s",
		strings.TrimRight(opts.endpoint, "/"), url.PathEscape(opts.bucket), url.PathEscape(name))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base, nil)
	if err != nil {
		return nil, "", false, err
	}
	resp, err := opts.client.Do(req)
	if err != nil {
		return nil, "", false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, "", false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return nil, "", false, fmt.Errorf("metadata GET returned HTTP %d: %s", resp.StatusCode, string(body))
	}
	var metadata struct {
		Generation string `json:"generation"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&metadata); err != nil {
		return nil, "", false, fmt.Errorf("decode object metadata: %w", err)
	}
	if metadata.Generation == "" {
		return nil, "", false, errors.New("object metadata omitted generation")
	}

	query := url.Values{"alt": {"media"}, "generation": {metadata.Generation}}
	mediaReq, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+query.Encode(), nil)
	if err != nil {
		return nil, "", false, err
	}
	mediaResp, err := opts.client.Do(mediaReq)
	if err != nil {
		return nil, "", false, err
	}
	defer mediaResp.Body.Close()
	if mediaResp.StatusCode < 200 || mediaResp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(mediaResp.Body, 4<<10))
		return nil, "", false, fmt.Errorf("media GET returned HTTP %d: %s", mediaResp.StatusCode, string(body))
	}
	data, err := io.ReadAll(io.LimitReader(mediaResp.Body, int64(maxBytes)+1))
	if err != nil {
		return nil, "", false, err
	}
	if len(data) > maxBytes {
		return nil, "", false, fmt.Errorf("stored object exceeds %d bytes", maxBytes)
	}
	return data, metadata.Generation, true, nil
}

func readBounded(path string, maxBytes int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", filepath.Base(path), err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("%s exceeds %d bytes", filepath.Base(path), maxBytes)
	}
	return data, nil
}

func parseSemver(value string) (semver, error) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return semver{}, errors.New("expected MAJOR.MINOR.PATCH")
	}
	values := make([]int, 3)
	for i, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return semver{}, errors.New("version fields must be canonical decimal integers")
		}
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 {
			return semver{}, errors.New("version fields must be canonical decimal integers")
		}
		values[i] = value
	}
	return semver{values[0], values[1], values[2]}, nil
}

func compareSemver(a, b semver) int {
	av := []int{a.major, a.minor, a.patch}
	bv := []int{b.major, b.minor, b.patch}
	for i := range av {
		if av[i] < bv[i] {
			return -1
		}
		if av[i] > bv[i] {
			return 1
		}
	}
	return 0
}

func (v semver) String() string {
	return fmt.Sprintf("%d.%d.%d", v.major, v.minor, v.patch)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
