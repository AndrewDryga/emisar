package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type storedObject struct {
	data         []byte
	generation   int
	contentType  string
	cacheControl string
}

type fakeGCS struct {
	mu      sync.Mutex
	objects map[string]storedObject
	order   []string
	client  *http.Client
	server  *httptest.Server
}

func newFakeGCS(t *testing.T) *fakeGCS {
	t.Helper()
	fake := &fakeGCS{objects: make(map[string]storedObject)}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serveHTTP))
	fake.client = fake.server.Client()
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeGCS) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.Contains(r.URL.Path, "/upload/") {
		f.upload(w, r)
		return
	}
	f.get(w, r)
}

func (f *fakeGCS) upload(w http.ResponseWriter, r *http.Request) {
	_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	reader := multipart.NewReader(r.Body, params["boundary"])
	metadataPart, err := reader.NextPart()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var metadata struct {
		Name         string `json:"name"`
		ContentType  string `json:"contentType"`
		CacheControl string `json:"cacheControl"`
	}
	if err := json.NewDecoder(metadataPart).Decode(&metadata); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	dataPart, err := reader.NextPart()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	data, err := io.ReadAll(dataPart)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	current, exists := f.objects[metadata.Name]
	precondition := r.URL.Query().Get("ifGenerationMatch")
	if (precondition == "0" && exists) || (exists && precondition != fmt.Sprint(current.generation)) {
		w.WriteHeader(http.StatusPreconditionFailed)
		return
	}
	if !exists && precondition != "0" {
		w.WriteHeader(http.StatusPreconditionFailed)
		return
	}
	generation := current.generation + 1
	f.objects[metadata.Name] = storedObject{
		data:         data,
		generation:   generation,
		contentType:  metadata.ContentType,
		cacheControl: metadata.CacheControl,
	}
	f.order = append(f.order, metadata.Name)
	w.WriteHeader(http.StatusOK)
}

func (f *fakeGCS) get(w http.ResponseWriter, r *http.Request) {
	index := strings.LastIndex(r.URL.Path, "/o/")
	if index == -1 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	name, err := url.PathUnescape(r.URL.Path[index+3:])
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	obj, ok := f.objects[name]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.URL.Query().Get("alt") == "media" {
		if r.URL.Query().Get("generation") != fmt.Sprint(obj.generation) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write(obj.data)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"generation": fmt.Sprint(obj.generation)})
}

func TestPublishUploadsImmutableObjectsBeforeLatest(t *testing.T) {
	dir := buildRelease(t, "runner", "1.2.3")
	fake := newFakeGCS(t)

	if err := publish(context.Background(), testOptions(dir, fake, "runner", "runner-v1.2.3", strings.Repeat("a", 40))); err != nil {
		t.Fatal(err)
	}

	latestName := "releases/runner/latest.json"
	if got := fake.order[len(fake.order)-1]; got != latestName {
		t.Fatalf("last upload = %q, want %q", got, latestName)
	}
	if got := fake.objects[latestName].cacheControl; got != "no-store" {
		t.Errorf("latest Cache-Control = %q", got)
	}
	for name, obj := range fake.objects {
		if name != latestName && obj.cacheControl != "public, max-age=31536000, immutable" {
			t.Errorf("%s Cache-Control = %q", name, obj.cacheControl)
		}
	}

	var manifest releaseManifest
	if err := json.Unmarshal(fake.objects[latestName].data, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.Tag != "runner-v1.2.3" || len(manifest.Artifacts) != 4 {
		t.Fatalf("latest manifest = %+v", manifest)
	}
}

func TestPublishIsIdempotentAndDoesNotMoveLatestBackward(t *testing.T) {
	fake := newFakeGCS(t)
	newer := buildRelease(t, "mcp", "2.0.0")
	opts := testOptions(newer, fake, "mcp", "mcp-v2.0.0", strings.Repeat("b", 40))
	if err := publish(context.Background(), opts); err != nil {
		t.Fatal(err)
	}
	firstLatest := fake.objects["releases/mcp/latest.json"]
	if err := publish(context.Background(), opts); err != nil {
		t.Fatalf("idempotent publish: %v", err)
	}

	older := buildRelease(t, "mcp", "1.9.9")
	if err := publish(context.Background(), testOptions(older, fake, "mcp", "mcp-v1.9.9", strings.Repeat("c", 40))); err != nil {
		t.Fatalf("older publish: %v", err)
	}
	after := fake.objects["releases/mcp/latest.json"]
	if after.generation != firstLatest.generation || string(after.data) != string(firstLatest.data) {
		t.Fatal("older release moved latest backward")
	}
}

func TestPublishMCPIncludesWindowsArchives(t *testing.T) {
	dir := buildRelease(t, "mcp", "1.2.3")
	fake := newFakeGCS(t)

	if err := publish(context.Background(), testOptions(dir, fake, "mcp", "mcp-v1.2.3", strings.Repeat("c", 40))); err != nil {
		t.Fatal(err)
	}

	names := []string{
		"emisar-mcp-1.2.3-windows-amd64.zip",
		"emisar-mcp-1.2.3-windows-arm64.zip",
	}
	for _, name := range names {
		objectName := "releases/mcp/mcp-v1.2.3/" + name
		if got := fake.objects[objectName].contentType; got != "application/zip" {
			t.Errorf("%s Content-Type = %q, want application/zip", objectName, got)
		}
	}

	var manifest releaseManifest
	if err := json.Unmarshal(fake.objects["releases/mcp/latest.json"].data, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Artifacts) != 6 || manifest.Artifacts[4].Name != names[0] || manifest.Artifacts[5].Name != names[1] {
		t.Fatalf("latest manifest artifacts = %+v", manifest.Artifacts)
	}
}

func TestPublishRunnerRejectsUnexpectedWindowsArchive(t *testing.T) {
	dir := buildRelease(t, "runner", "1.2.3")
	name := "emisar-1.2.3-windows-arm64.zip"
	data := []byte("runner-windows-arm64")
	if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	line := fmt.Sprintf("%s  %s\n", hex.EncodeToString(sum[:]), name)
	checksumsPath := filepath.Join(dir, "SHA256SUMS")
	checksums, err := os.ReadFile(checksumsPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(checksumsPath, append(checksums, line...), 0o600); err != nil {
		t.Fatal(err)
	}

	fake := newFakeGCS(t)
	err = publish(context.Background(), testOptions(dir, fake, "runner", "runner-v1.2.3", strings.Repeat("d", 40)))
	if err == nil || !strings.Contains(err.Error(), "unexpected checksum line") {
		t.Fatalf("error = %v", err)
	}
	if len(fake.order) != 0 {
		t.Fatalf("uploaded before validation: %v", fake.order)
	}
}

func TestPublishRejectsChecksumMismatchBeforeUpload(t *testing.T) {
	dir := buildRelease(t, "runner", "1.2.3")
	path := filepath.Join(dir, "emisar-1.2.3-linux-amd64.tar.gz")
	if err := os.WriteFile(path, []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	fake := newFakeGCS(t)
	err := publish(context.Background(), testOptions(dir, fake, "runner", "runner-v1.2.3", strings.Repeat("d", 40)))
	if err == nil || !strings.Contains(err.Error(), "digest is") {
		t.Fatalf("error = %v", err)
	}
	if len(fake.order) != 0 {
		t.Fatalf("uploaded before validation: %v", fake.order)
	}
}

func TestPublishRejectsDifferentBytesAtImmutablePath(t *testing.T) {
	dir := buildRelease(t, "runner", "1.2.3")
	fake := newFakeGCS(t)
	opts := testOptions(dir, fake, "runner", "runner-v1.2.3", strings.Repeat("e", 40))
	if err := publish(context.Background(), opts); err != nil {
		t.Fatal(err)
	}
	name := "releases/runner/runner-v1.2.3/emisar-1.2.3-darwin-amd64.tar.gz"
	obj := fake.objects[name]
	obj.data = []byte("poisoned")
	fake.objects[name] = obj
	if err := publish(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "different bytes") {
		t.Fatalf("error = %v", err)
	}
}

func testOptions(dir string, fake *fakeGCS, component, tag, revision string) options {
	return options{
		dir:            dir,
		bucket:         "bucket",
		component:      component,
		tag:            tag,
		sourceRevision: revision,
		token:          "token",
		endpoint:       fake.server.URL,
		client:         fake.client,
	}
}

func buildRelease(t *testing.T, component, version string) string {
	t.Helper()
	dir := t.TempDir()
	prefix := "emisar-"
	checksumsName := "SHA256SUMS"
	if component == "mcp" {
		prefix = "emisar-mcp-"
		checksumsName = "SHA256SUMS-MCP"
	}
	platforms := []string{"darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64"}
	if component == "mcp" {
		platforms = append(platforms, "windows-amd64", "windows-arm64")
	}

	var checksums strings.Builder
	for _, platform := range platforms {
		extension := ".tar.gz"
		if strings.HasPrefix(platform, "windows-") {
			extension = ".zip"
		}
		name := prefix + version + "-" + platform + extension
		data := []byte(component + "-" + platform)
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(data)
		digest := hex.EncodeToString(sum[:])
		if err := os.WriteFile(filepath.Join(dir, name+".sha256"), []byte(digest+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(&checksums, "%s  %s\n", digest, name)
	}
	if err := os.WriteFile(filepath.Join(dir, checksumsName), []byte(checksums.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}
