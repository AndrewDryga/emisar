// Package selfupdate verifies and hands a runner release to the official installer.
package selfupdate

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
)

const (
	officialRepository = "andrewdryga/emisar"
	// Post-split releases are attested by the reusable trusted workflow; the
	// certificate SAN carries that workflow rather than its thin caller.
	signerWorkflow = "AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml"
	// The repository is moving to the EmisarHQ organization. Releases signed
	// after the transfer carry the successor spelling in their certificate,
	// while the fleet's already-written receipts and pre-transfer releases
	// carry the current one — so verification accepts either identity until
	// the transfer completes and a later release retires the old spelling.
	// The current identity is tried first because it signs every release
	// until the repository actually moves.
	successorRepository     = "emisarhq/emisar"
	successorSignerWorkflow = "EmisarHQ/emisar/.github/workflows/runner-release-trusted.yml"
	legacyRunnerTag         = "runner-v0.22.1"
	legacySignerWorkflow    = "AndrewDryga/emisar/.github/workflows/runner-release.yml"
	legacySignerDigest      = "642128eb48205405fd44ce845118e6a68737eea2"
	releaseBaseURL          = "https://emisar.dev/releases/runner"
	apiBaseURL              = "https://api.github.com"
	downloadBaseURL         = "https://github.com"
	maxAPIBytes             = 4 << 20
	maxManifestBytes        = 1 << 20
	maxChecksumsBytes       = 1 << 20
	maxArchiveBytes         = 256 << 20
	maxInstallerBytes       = 512 << 10
	maxBinaryBytes          = 128 << 20
)

// Options are the operator choices and output streams for one update.
type Options struct {
	Version        string
	CurrentVersion string
	Stdout         io.Writer
	Stderr         io.Writer
}

type dependencies struct {
	executable   func() (string, error)
	effectiveID  func() int
	trustPath    func(string, fs.FileInfo) error
	lookPath     func(string) (string, error)
	runCommand   func(context.Context, string, []string, []string, io.Writer, io.Writer) error
	httpClient   *http.Client
	releaseBase  string
	apiBase      string
	downloadBase string
	tempRoot     string
}

type release struct {
	TagName    string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Immutable  bool   `json:"immutable"`
	BaseURL    string `json:"-"`
	Fallback   bool   `json:"-"`
}

type mirrorManifest struct {
	SchemaVersion  int    `json:"schema_version"`
	Component      string `json:"component"`
	Tag            string `json:"tag"`
	Version        string `json:"version"`
	SourceRevision string `json:"source_revision"`
}

type semver struct {
	major int
	minor int
	patch int
}

// Run verifies an immutable release and delegates the actual replacement to
// the installer bundled inside it.
func Run(ctx context.Context, opts Options) error {
	client := httpsecurity.RefuseDowngradeRedirects(
		httpsecurity.ClientWithTLS12(&http.Client{Timeout: 5 * time.Minute}),
	)
	return run(ctx, opts, dependencies{
		executable:   os.Executable,
		effectiveID:  effectiveUID,
		trustPath:    requireRootOwnedPath,
		lookPath:     trustedLookPath,
		runCommand:   execute,
		httpClient:   client,
		releaseBase:  releaseBaseURL,
		apiBase:      apiBaseURL,
		downloadBase: downloadBaseURL,
	})
}

func run(ctx context.Context, opts Options, deps dependencies) error {
	if opts.Stdout == nil {
		opts.Stdout = io.Discard
	}
	if opts.Stderr == nil {
		opts.Stderr = io.Discard
	}
	if deps.effectiveID() != 0 {
		return errors.New("self-update requires root; run sudo emisar update")
	}

	executable, err := deps.executable()
	if err != nil {
		return fmt.Errorf("resolve current executable: %w", err)
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return fmt.Errorf("resolve current executable links: %w", err)
	}
	receipt, err := loadReceipt(executable, deps.trustPath)
	if err != nil {
		return fmt.Errorf(
			"self-update is unavailable for this runner: %w; update it with the installer, image, or infrastructure definition that owns it",
			err,
		)
	}

	target, err := resolveRelease(ctx, opts.Version, deps)
	if err != nil {
		return err
	}
	if target.Fallback {
		fmt.Fprintln(opts.Stderr, "warning: Emisar release mirror unavailable; using the GitHub release mirror")
	}
	targetVersion := strings.TrimPrefix(target.TagName, "runner-v")
	if sameOrNewer(opts.CurrentVersion, targetVersion, opts.Version == "") {
		fmt.Fprintf(opts.Stdout, "emisar %s is already current.\n", opts.CurrentVersion)
		return nil
	}

	temp, err := os.MkdirTemp(deps.tempRoot, "emisar-update-")
	if err != nil {
		return fmt.Errorf("create update directory: %w", err)
	}
	defer os.RemoveAll(temp)
	if err := os.Chmod(temp, 0o700); err != nil {
		return fmt.Errorf("secure update directory: %w", err)
	}

	name := fmt.Sprintf("emisar-%s-%s-%s", targetVersion, runtime.GOOS, runtime.GOARCH)
	archiveName := name + ".tar.gz"
	archivePath := filepath.Join(temp, archiveName)
	checksumsPath := filepath.Join(temp, "SHA256SUMS")
	base := target.BaseURL

	fmt.Fprintf(opts.Stdout, "Downloading emisar %s for %s/%s...\n", targetVersion, runtime.GOOS, runtime.GOARCH)
	if err := downloadReleaseFiles(ctx, deps.httpClient, base, archiveName, archivePath, checksumsPath); err != nil {
		if target.Fallback {
			return err
		}
		fmt.Fprintln(opts.Stderr, "warning: Emisar release download failed; using the GitHub release mirror")
		if err := os.Remove(archivePath); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("remove partial release archive: %w", err)
		}
		if err := os.Remove(checksumsPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("remove partial release checksums: %w", err)
		}
		fallback, resolveErr := resolveGitHubRelease(ctx, target.TagName, deps)
		if resolveErr != nil {
			return fmt.Errorf("resolve GitHub release mirror after Emisar download failure: %w", resolveErr)
		}
		if err := downloadReleaseFiles(ctx, deps.httpClient, fallback.BaseURL, archiveName, archivePath, checksumsPath); err != nil {
			return fmt.Errorf("both release mirrors failed: %w", err)
		}
	}
	digest, err := verifyChecksum(archivePath, checksumsPath, archiveName)
	if err != nil {
		return err
	}
	fmt.Fprintf(opts.Stdout, "Verified checksum sha256:%s…\n", digest[:16])

	identity, err := verifyProvenance(ctx, archivePath, target.TagName, deps, opts.Stdout, opts.Stderr)
	if err != nil {
		return err
	}
	bundle, err := extractBundle(archivePath, temp, name)
	if err != nil {
		return err
	}

	fmt.Fprintf(opts.Stdout, "Updating emisar %s to %s...\n", opts.CurrentVersion, targetVersion)
	args, env := installerInvocation(bundle, target.TagName, receipt, identity)
	if err := deps.runCommand(ctx, "/bin/bash", args, env, opts.Stdout, opts.Stderr); err != nil {
		return fmt.Errorf("release installer failed: %w", err)
	}
	return nil
}

func resolveRelease(ctx context.Context, requested string, deps dependencies) (release, error) {
	tag := ""
	if requested != "" {
		var err error
		tag, err = normalizeVersion(requested)
		if err != nil {
			return release{}, err
		}
	}
	found, unavailable, err := resolveMirrorRelease(ctx, tag, deps)
	if err != nil {
		return release{}, err
	}
	if !unavailable {
		return found, nil
	}
	found, err = resolveGitHubRelease(ctx, tag, deps)
	if err != nil {
		return release{}, err
	}
	found.Fallback = true
	return found, nil
}

func resolveMirrorRelease(ctx context.Context, tag string, deps dependencies) (release, bool, error) {
	path := "/latest.json"
	if tag != "" {
		path = "/" + tag + "/manifest.json"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(deps.releaseBase, "/")+path, nil)
	if err != nil {
		return release{}, false, fmt.Errorf("build Emisar release request: %w", err)
	}
	resp, err := deps.httpClient.Do(req)
	if err != nil {
		return release{}, true, nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return release{}, true, nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxManifestBytes+1))
	if err != nil {
		return release{}, false, fmt.Errorf("read Emisar release manifest: %w", err)
	}
	if len(body) > maxManifestBytes {
		return release{}, false, fmt.Errorf("emisar release manifest exceeds the %d-byte limit", maxManifestBytes)
	}
	var manifest mirrorManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return release{}, false, fmt.Errorf("decode Emisar release manifest: %w", err)
	}
	version, ok := parseTag(manifest.Tag)
	revision, revisionErr := hex.DecodeString(manifest.SourceRevision)
	if manifest.SchemaVersion != 1 || manifest.Component != "runner" || !ok ||
		manifest.Version != fmt.Sprintf("%d.%d.%d", version.major, version.minor, version.patch) ||
		revisionErr != nil || len(revision) != 20 || manifest.SourceRevision != strings.ToLower(manifest.SourceRevision) {
		return release{}, false, errors.New("emisar release mirror returned an invalid runner manifest")
	}
	if tag != "" && manifest.Tag != tag {
		return release{}, false, fmt.Errorf("emisar release mirror returned %s for %s", manifest.Tag, tag)
	}
	return release{
		TagName: manifest.Tag,
		BaseURL: strings.TrimRight(deps.releaseBase, "/") + "/" + manifest.Tag,
	}, false, nil
}

func resolveGitHubRelease(ctx context.Context, requested string, deps dependencies) (release, error) {
	if requested != "" {
		tag, err := normalizeVersion(requested)
		if err != nil {
			return release{}, err
		}
		var found release
		path := "/repos/" + officialRepository + "/releases/tags/" + tag
		if err := getJSON(ctx, deps, path, &found); err != nil {
			return release{}, fmt.Errorf("resolve %s: %w", tag, err)
		}
		if found.TagName != tag || found.Draft || found.Prerelease || !found.Immutable {
			return release{}, fmt.Errorf("release %s is not a stable immutable runner release", tag)
		}
		found.BaseURL = githubDownloadBase(deps, tag)
		return found, nil
	}

	var releases []release
	if err := getJSON(ctx, deps, "/repos/"+officialRepository+"/releases?per_page=100", &releases); err != nil {
		return release{}, fmt.Errorf("resolve latest runner release: %w", err)
	}
	type candidate struct {
		release release
		version semver
	}
	var candidates []candidate
	for _, item := range releases {
		version, ok := parseTag(item.TagName)
		if !ok || item.Draft || item.Prerelease || !item.Immutable {
			continue
		}
		candidates = append(candidates, candidate{release: item, version: version})
	}
	if len(candidates) == 0 {
		return release{}, errors.New("no stable immutable runner release was found")
	}
	sort.Slice(candidates, func(i, j int) bool {
		return compare(candidates[i].version, candidates[j].version) > 0
	})
	found := candidates[0].release
	found.BaseURL = githubDownloadBase(deps, found.TagName)
	return found, nil
}

func githubDownloadBase(deps dependencies, tag string) string {
	return strings.TrimRight(deps.downloadBase, "/") + "/" + officialRepository + "/releases/download/" + tag
}

func downloadReleaseFiles(ctx context.Context, client *http.Client, base, archiveName, archivePath, checksumsPath string) error {
	if err := download(ctx, client, base+"/"+archiveName, archivePath, maxArchiveBytes); err != nil {
		return fmt.Errorf("download release archive: %w", err)
	}
	if err := download(ctx, client, base+"/SHA256SUMS", checksumsPath, maxChecksumsBytes); err != nil {
		return fmt.Errorf("download release checksums: %w", err)
	}
	return nil
}

func getJSON(ctx context.Context, deps dependencies, path string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(deps.apiBase, "/")+path, nil)
	if err != nil {
		return fmt.Errorf("build GitHub request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	if token := os.Getenv("EMISAR_GITHUB_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := deps.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("query GitHub releases: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub releases API returned %s; set EMISAR_GITHUB_TOKEN if this host shares an API rate limit", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxAPIBytes+1))
	if err != nil {
		return fmt.Errorf("read GitHub releases response: %w", err)
	}
	if len(body) > maxAPIBytes {
		return fmt.Errorf("GitHub releases response exceeds the %d-byte limit", maxAPIBytes)
	}
	if err := json.Unmarshal(body, into); err != nil {
		return fmt.Errorf("decode GitHub releases response: %w", err)
	}
	return nil
}

func normalizeVersion(value string) (string, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "runner-")
	value = strings.TrimPrefix(value, "v")
	if _, ok := parseSemver(value); !ok {
		return "", fmt.Errorf("version must match MAJOR.MINOR.PATCH (got %q)", value)
	}
	return "runner-v" + value, nil
}

func parseTag(tag string) (semver, bool) {
	if !strings.HasPrefix(tag, "runner-v") {
		return semver{}, false
	}
	return parseSemver(strings.TrimPrefix(tag, "runner-v"))
}

func parseSemver(value string) (semver, bool) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return semver{}, false
	}
	values := make([]int, 3)
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return semver{}, false
		}
		parsed, err := strconv.Atoi(part)
		if err != nil || parsed < 0 {
			return semver{}, false
		}
		values[index] = parsed
	}
	return semver{major: values[0], minor: values[1], patch: values[2]}, true
}

func compare(left, right semver) int {
	for _, pair := range [][2]int{{left.major, right.major}, {left.minor, right.minor}, {left.patch, right.patch}} {
		if pair[0] < pair[1] {
			return -1
		}
		if pair[0] > pair[1] {
			return 1
		}
	}
	return 0
}

func sameOrNewer(current, target string, latest bool) bool {
	currentVersion, currentOK := parseSemver(strings.TrimPrefix(strings.TrimPrefix(current, "runner-"), "v"))
	targetVersion, targetOK := parseSemver(target)
	if !currentOK || !targetOK {
		return false
	}
	result := compare(currentVersion, targetVersion)
	return result == 0 || (latest && result > 0)
}

func download(ctx context.Context, client *http.Client, url, destination string, maximum int64) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("build download request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("server returned %s", resp.Status)
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create %s: %w", filepath.Base(destination), err)
	}
	written, copyErr := io.Copy(file, io.LimitReader(resp.Body, maximum+1))
	closeErr := file.Close()
	if copyErr != nil {
		return fmt.Errorf("write %s: %w", filepath.Base(destination), copyErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close %s: %w", filepath.Base(destination), closeErr)
	}
	if written > maximum {
		return fmt.Errorf("%s exceeds the %d-byte download limit", filepath.Base(destination), maximum)
	}
	return nil
}

func verifyChecksum(archivePath, checksumsPath, archiveName string) (string, error) {
	data, err := os.ReadFile(checksumsPath)
	if err != nil {
		return "", fmt.Errorf("read release checksums: %w", err)
	}
	var expected string
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || strings.TrimPrefix(fields[1], "*") != archiveName {
			continue
		}
		if expected != "" {
			return "", fmt.Errorf("release checksums contain duplicate entries for %s", archiveName)
		}
		if len(fields[0]) != 64 {
			return "", fmt.Errorf("release checksum for %s is malformed", archiveName)
		}
		if _, err := hex.DecodeString(fields[0]); err != nil {
			return "", fmt.Errorf("release checksum for %s is malformed", archiveName)
		}
		expected = strings.ToLower(fields[0])
	}
	if expected == "" {
		return "", fmt.Errorf("release checksums do not name %s", archiveName)
	}
	archive, err := os.Open(archivePath)
	if err != nil {
		return "", fmt.Errorf("open release archive: %w", err)
	}
	hash := sha256.New()
	_, copyErr := io.Copy(hash, archive)
	closeErr := archive.Close()
	if copyErr != nil {
		return "", fmt.Errorf("hash release archive: %w", copyErr)
	}
	if closeErr != nil {
		return "", fmt.Errorf("close release archive: %w", closeErr)
	}
	actual := hex.EncodeToString(hash.Sum(nil))
	if actual != expected {
		return "", fmt.Errorf("checksum verification failed for %s", archiveName)
	}
	return actual, nil
}

// releaseIdentity pairs the GitHub repository queried for attestations with
// the workflow identity those attestations are signed under. The two always
// travel together: mixing one identity's repository with the other's workflow
// only verifies by accident of GitHub's rename redirects.
type releaseIdentity struct {
	repository string
	workflow   string
	digest     string
}

func acceptedIdentities(tag string) []releaseIdentity {
	if tag == legacyRunnerTag {
		return []releaseIdentity{
			{repository: officialRepository, workflow: legacySignerWorkflow, digest: legacySignerDigest},
		}
	}
	return []releaseIdentity{
		{repository: officialRepository, workflow: signerWorkflow},
		{repository: successorRepository, workflow: successorSignerWorkflow},
	}
}

// verifyProvenance returns the identity the archive verified against, so the
// installer invocation re-checks the same pair rather than a hardcoded one.
// When verification is skipped it returns the first accepted identity — the
// same spelling the skip warning tells the operator to verify by hand.
func verifyProvenance(ctx context.Context, archive, tag string, deps dependencies, stdout, stderr io.Writer) (releaseIdentity, error) {
	identities := acceptedIdentities(tag)
	gh, err := deps.lookPath("gh")
	if err != nil {
		fmt.Fprintln(stderr, "warning: gh is not installed; release provenance was not checked")
		return identities[0], nil
	}
	env := verifierEnvironment()
	if err := deps.runCommand(ctx, gh, []string{"auth", "status"}, env, io.Discard, io.Discard); err != nil {
		fmt.Fprintln(stderr, "warning: gh is not authenticated; release provenance was not checked")
		return identities[0], nil
	}
	var lastErr error
	for _, identity := range identities {
		args := []string{
			"attestation", "verify", archive,
			"--repo", identity.repository,
			"--signer-workflow", identity.workflow,
			"--source-ref", "refs/tags/" + tag,
		}
		if identity.digest != "" {
			args = append(args, "--signer-digest", identity.digest)
		}
		args = append(args, "--deny-self-hosted-runners")
		if err := deps.runCommand(ctx, gh, args, env, io.Discard, io.Discard); err != nil {
			lastErr = err
			continue
		}
		fmt.Fprintln(stdout, "Verified GitHub build provenance.")
		return identity, nil
	}
	workflows := make([]string, 0, len(identities))
	for _, identity := range identities {
		workflows = append(workflows, identity.workflow)
	}
	return releaseIdentity{}, fmt.Errorf(
		"release attestation did not verify against %s: %w",
		strings.Join(workflows, " or "), lastErr,
	)
}

func verifierEnvironment() []string {
	env := os.Environ()
	if os.Getenv("GH_TOKEN") == "" && os.Getenv("GITHUB_TOKEN") == "" {
		if token := os.Getenv("EMISAR_GITHUB_TOKEN"); token != "" {
			env = append(env, "GH_TOKEN="+token)
		}
	}
	return env
}

func trustedLookPath(name string) (string, error) {
	path, err := exec.LookPath(name)
	if err != nil {
		return "", err
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", name, err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("inspect %s: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%s is not a regular file", path)
	}
	if err := requireRootOwnedPath(path, info); err != nil {
		return "", err
	}
	return path, nil
}

func extractBundle(archivePath, destination, name string) (string, error) {
	archive, err := os.Open(archivePath)
	if err != nil {
		return "", fmt.Errorf("open verified release archive: %w", err)
	}
	defer archive.Close()
	gzipReader, err := gzip.NewReader(archive)
	if err != nil {
		return "", fmt.Errorf("open verified release gzip: %w", err)
	}
	defer gzipReader.Close()

	bundle := filepath.Join(destination, name)
	if err := os.Mkdir(bundle, 0o700); err != nil {
		return "", fmt.Errorf("create verified bundle directory: %w", err)
	}
	wanted := map[string]struct {
		limit int64
		mode  fs.FileMode
	}{
		name + "/emisar":     {limit: maxBinaryBytes, mode: 0o755},
		name + "/install.sh": {limit: maxInstallerBytes, mode: 0o700},
	}
	found := make(map[string]bool, len(wanted))
	reader := tar.NewReader(gzipReader)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", fmt.Errorf("read verified release archive: %w", err)
		}
		entry, ok := wanted[header.Name]
		if !ok {
			continue
		}
		if found[header.Name] {
			return "", fmt.Errorf("verified release archive repeats %s", header.Name)
		}
		if header.Typeflag != tar.TypeReg || header.Size < 1 || header.Size > entry.limit {
			return "", fmt.Errorf("verified release archive has invalid %s", header.Name)
		}
		target := filepath.Join(bundle, filepath.Base(header.Name))
		file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, entry.mode)
		if err != nil {
			return "", fmt.Errorf("create verified %s: %w", filepath.Base(target), err)
		}
		written, copyErr := io.CopyN(file, reader, header.Size)
		closeErr := file.Close()
		if copyErr != nil || written != header.Size {
			return "", fmt.Errorf("extract verified %s: %w", filepath.Base(target), copyErr)
		}
		if closeErr != nil {
			return "", fmt.Errorf("close verified %s: %w", filepath.Base(target), closeErr)
		}
		found[header.Name] = true
	}
	for path := range wanted {
		if !found[path] {
			return "", fmt.Errorf("verified release archive is missing %s", path)
		}
	}
	return bundle, nil
}

func installerInvocation(bundle, tag string, receipt receipt, identity releaseIdentity) ([]string, []string) {
	args := []string{
		filepath.Join(bundle, "install.sh"),
		"--version", tag,
		"--yes",
		"--packs", "",
		"--bin-dir", filepath.Dir(receipt.Binary),
		"--etc-dir", receipt.EtcDir,
		"--data-dir", receipt.DataDir,
		"--log-dir", receipt.LogDir,
		"--preverified-bundle", bundle,
	}
	if receipt.Init == "none" {
		args = append(args, "--no-service")
	}

	blocked := map[string]bool{
		"ASSUME_YES": true, "BIN_DIR": true, "DATA_DIR": true,
		"BASH_ENV": true, "BASHOPTS": true, "CDPATH": true,
		"DYLD_INSERT_LIBRARIES": true, "DYLD_LIBRARY_PATH": true,
		"EMISAR_ATTESTATION_WORKFLOW": true, "EMISAR_ENROLLMENT_KEY": true,
		"EMISAR_GITHUB_TOKEN": true, "EMISAR_PACKS": true, "EMISAR_REPO": true,
		"ENV": true, "ETC_DIR": true, "GITHUB_TOKEN": true, "GH_TOKEN": true,
		"LD_LIBRARY_PATH": true, "LD_PRELOAD": true,
		"LOG_DIR": true, "NO_SERVICE": true, "NO_START": true,
		"PATH": true, "QUARANTINE_DISPATCH_LOG": true, "SERVICE_GROUP": true,
		"SERVICE_USER": true, "VERSION": true,
		"SHELLOPTS": true,
	}
	env := make([]string, 0, len(os.Environ())+8)
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if blocked[key] || strings.HasPrefix(key, "EMISAR_RUNNER_LABEL_") ||
			key == "EMISAR_GROUP" || key == "EMISAR_RUNNER_ID" {
			continue
		}
		env = append(env, item)
	}
	env = append(env,
		"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
		"EMISAR_REPO="+identity.repository,
		"EMISAR_ATTESTATION_WORKFLOW="+identity.workflow,
		"EMISAR_PACKS=",
		"SERVICE_USER="+receipt.ServiceUser,
		"SERVICE_GROUP="+receipt.ServiceGroup,
	)
	return args, env
}

func execute(ctx context.Context, name string, args, env []string, stdout, stderr io.Writer) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Env = env
	command.Stdout = stdout
	command.Stderr = stderr
	return command.Run()
}
