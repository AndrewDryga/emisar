package catalog

import (
	"context"
	"encoding/json"
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

// buildTree writes a fixture artifact tree and returns its dir.
func buildTree(t *testing.T) string {
	t.Helper()
	reg, cat := buildFixtureCatalog(t)
	out := t.TempDir()
	if _, err := Write(reg, cat, out); err != nil {
		t.Fatal(err)
	}
	return out
}

// readManifest loads the manifest.json a built tree carries at its root.
func readManifest(t *testing.T, dir string) Manifest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	return m
}

// fakeGCS records upload requests and lets a test choose the status per
// object path (default 200).
type fakeGCS struct {
	mu       sync.Mutex
	requests map[string]string // object name -> ifGenerationMatch value ("" if absent)
	auth     map[string]string // object name -> Authorization header
	readAuth map[string]string // object name -> Authorization header on collision verification
	cache    map[string]string // object name -> Cache-Control metadata
	status   map[string]int    // object name -> forced status
	objects  map[string][]byte // bytes returned when an existing object is verified
	order    []string          // object names in the order they were uploaded
}

func newFakeGCS() *fakeGCS {
	return &fakeGCS{
		requests: map[string]string{},
		auth:     map[string]string{},
		readAuth: map[string]string{},
		cache:    map[string]string{},
		status:   map[string]int{},
		objects:  map[string][]byte{},
	}
}

func (f *fakeGCS) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			idx := strings.LastIndex(r.URL.Path, "/o/")
			if idx == -1 {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			name, err := url.PathUnescape(r.URL.Path[idx+3:])
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			f.mu.Lock()
			data, ok := f.objects[name]
			f.readAuth[name] = r.Header.Get("Authorization")
			f.mu.Unlock()
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(data)
			return
		}
		_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil {
			t.Errorf("parse upload content type: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		part, err := multipart.NewReader(r.Body, params["boundary"]).NextPart()
		if err != nil {
			t.Errorf("read metadata part: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var metadata struct {
			Name         string `json:"name"`
			CacheControl string `json:"cacheControl"`
		}
		if err := json.NewDecoder(part).Decode(&metadata); err != nil {
			t.Errorf("decode metadata: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		name := metadata.Name
		f.mu.Lock()
		f.requests[name] = r.URL.Query().Get("ifGenerationMatch")
		f.auth[name] = r.Header.Get("Authorization")
		f.cache[name] = metadata.CacheControl
		f.order = append(f.order, name)
		code := f.status[name]
		f.mu.Unlock()
		if code == 0 {
			code = http.StatusOK
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestPublish_PreconditionsPerObjectKind(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	srv := f.server(t)

	res, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if len(res.Uploaded) == 0 {
		t.Fatal("nothing uploaded")
	}
	if len(res.Skipped) != 0 {
		t.Errorf("expected no skips, got %v", res.Skipped)
	}

	// Immutable objects carry ifGenerationMatch=0; mutable pointers don't.
	if got := f.requests["v1/catalog.json"]; got != "" {
		t.Errorf("mutable catalog.json sent ifGenerationMatch=%q, want none", got)
	}
	if got := f.requests["v1/suggest.json"]; got != "" {
		t.Errorf("mutable suggest.json sent ifGenerationMatch=%q, want none", got)
	}
	sawImmutable := false
	for name, igm := range f.requests {
		if name == "v1/catalog.json" || name == "v1/suggest.json" {
			continue
		}
		sawImmutable = true
		if igm != "0" {
			t.Errorf("immutable %s sent ifGenerationMatch=%q, want 0", name, igm)
		}
	}
	if !sawImmutable {
		t.Error("expected at least one immutable object")
	}
	if got := f.auth["v1/catalog.json"]; got != "Bearer tok" {
		t.Errorf("Authorization = %q, want Bearer tok", got)
	}
	if got := f.cache["v1/catalog.json"]; got != "no-store" {
		t.Errorf("mutable catalog Cache-Control = %q, want no-store", got)
	}
	for name, cacheControl := range f.cache {
		if name == "v1/catalog.json" || name == "v1/suggest.json" {
			continue
		}
		if cacheControl != "public, max-age=31536000, immutable" {
			t.Errorf("immutable %s Cache-Control = %q", name, cacheControl)
		}
	}
}

func TestPublish_ImmutableObjectsUploadedBeforeMutablePointers(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	srv := f.server(t)

	if _, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	}); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// Classify every object from the manifest so the guarantee holds for any
	// future pointer, not just today's catalog.json/suggest.json.
	immutable := map[string]bool{}
	for _, obj := range readManifest(t, dir).Objects {
		immutable[obj.Path] = obj.Immutable
	}

	// A mutable pointer must never be uploaded before an immutable object it may
	// reference — otherwise a mid-publish crash leaves the live pointer resolving
	// to a 404 (PUBLISHING.md: "the mutable pointers are overwritten last").
	sawMutable := false
	for _, name := range f.order {
		if immutable[name] {
			if sawMutable {
				t.Errorf("immutable %s uploaded after a mutable pointer; immutable must go first", name)
			}
			continue
		}
		sawMutable = true
	}
	if !sawMutable {
		t.Fatal("expected at least one mutable pointer in the upload order")
	}
}

func TestPublish_ExistingImmutableIsSkipped(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	// A schema object already exists with the expected bytes: the publisher
	// verifies it before treating the precondition failure as idempotent.
	const name = "v1/schemas/catalog.v3.schema.json"
	f.status[name] = http.StatusPreconditionFailed
	existing, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(name)))
	if err != nil {
		t.Fatalf("read existing immutable fixture: %v", err)
	}
	f.objects[name] = existing
	srv := f.server(t)

	res, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err != nil {
		t.Fatalf("Publish should not error on an existing immutable object: %v", err)
	}
	found := false
	for _, s := range res.Skipped {
		if s == name {
			found = true
		}
	}
	if !found {
		t.Errorf("existing immutable object not reported as skipped: %v", res.Skipped)
	}
	if got := f.readAuth[name]; got != "" {
		t.Errorf("immutable collision verification used publisher credentials: %q", got)
	}
}

func TestPublish_ExistingImmutableWithDifferentBytesFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v3.schema.json"
	f.status[name] = http.StatusPreconditionFailed
	f.objects[name] = []byte("different")
	srv := f.server(t)

	_, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err == nil || !strings.Contains(err.Error(), "different bytes") {
		t.Fatalf("expected immutable-byte mismatch, got %v", err)
	}
	assertMutablePointersUntouched(t, f)
}

func TestPublish_ExistingImmutableThatCannotBeReadFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v3.schema.json"
	f.status[name] = http.StatusPreconditionFailed
	srv := f.server(t)

	_, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err == nil || !strings.Contains(err.Error(), "verify existing immutable object") {
		t.Fatalf("expected immutable verification failure, got %v", err)
	}
	assertMutablePointersUntouched(t, f)
}

func TestPublish_OversizedExistingImmutableFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v3.schema.json"
	f.status[name] = http.StatusPreconditionFailed
	expected, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(name)))
	if err != nil {
		t.Fatalf("read immutable fixture: %v", err)
	}
	f.objects[name] = make([]byte, len(expected)+1)
	srv := f.server(t)

	_, err = Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err == nil || !strings.Contains(err.Error(), "exceeds expected size") {
		t.Fatalf("expected oversized immutable failure, got %v", err)
	}
	assertMutablePointersUntouched(t, f)
}

func assertMutablePointersUntouched(t *testing.T, f *fakeGCS) {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, name := range []string{"v1/catalog.json", "v1/suggest.json"} {
		if _, ok := f.requests[name]; ok {
			t.Errorf("mutable pointer %s was published after immutable verification failed", name)
		}
	}
}

func TestPublish_ServerErrorFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	f.status["v1/catalog.json"] = http.StatusInternalServerError
	srv := f.server(t)

	_, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "test-bucket",
		Token:    "tok",
		Endpoint: srv.URL,
	})
	if err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestPublish_RequiresToken(t *testing.T) {
	dir := buildTree(t)
	if _, err := Publish(context.Background(), dir, PublishOptions{Bucket: "b"}); err == nil {
		t.Fatal("expected error when no token and not dry-run")
	}
}

func TestPublish_DryRunUploadsNothing(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	srv := f.server(t)

	res, err := Publish(context.Background(), dir, PublishOptions{
		Bucket:   "b",
		Endpoint: srv.URL,
		DryRun:   true,
	})
	if err != nil {
		t.Fatalf("dry-run Publish: %v", err)
	}
	if len(res.Uploaded) == 0 {
		t.Error("dry-run should list objects it would upload")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.requests) != 0 {
		t.Errorf("dry-run must not contact the server, got %d requests", len(f.requests))
	}
}
