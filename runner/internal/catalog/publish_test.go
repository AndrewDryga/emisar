package catalog

import (
	"bytes"
	"compress/gzip"
	"context"
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
	// privateReads makes the fake refuse an unauthenticated GET like a private
	// self-hosted bucket does; the public registry serves reads to anyone.
	privateReads bool
	cache        map[string]string // object name -> Cache-Control metadata
	encoding     map[string]string // object name -> Content-Encoding metadata ("" if absent)
	stored       map[string][]byte // object name -> uploaded data-part bytes
	status       map[string]int    // object name -> forced status
	objects      map[string][]byte // bytes returned when an existing object is verified
	order        []string          // object names in the order they were uploaded
}

func newFakeGCS() *fakeGCS {
	return &fakeGCS{
		requests: map[string]string{},
		auth:     map[string]string{},
		readAuth: map[string]string{},
		cache:    map[string]string{},
		encoding: map[string]string{},
		stored:   map[string][]byte{},
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
			private := f.privateReads
			f.mu.Unlock()
			if private && r.Header.Get("Authorization") == "" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
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
		reader := multipart.NewReader(r.Body, params["boundary"])
		part, err := reader.NextPart()
		if err != nil {
			t.Errorf("read metadata part: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var metadata struct {
			Name            string `json:"name"`
			ContentEncoding string `json:"contentEncoding"`
			CacheControl    string `json:"cacheControl"`
		}
		if err := json.NewDecoder(part).Decode(&metadata); err != nil {
			t.Errorf("decode metadata: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		dataPart, err := reader.NextPart()
		if err != nil {
			t.Errorf("read data part: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(dataPart)
		if err != nil {
			t.Errorf("read data part bytes: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		name := metadata.Name
		f.mu.Lock()
		f.requests[name] = r.URL.Query().Get("ifGenerationMatch")
		f.auth[name] = r.Header.Get("Authorization")
		f.cache[name] = metadata.CacheControl
		f.encoding[name] = metadata.ContentEncoding
		f.stored[name] = body
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

	m := readManifest(t, dir)

	// Which objects are mutable is the MANIFEST's answer, not a list repeated
	// here: hard-coding the two v1/ pointers meant every later mutable object —
	// the packs.json / packs/suggest.json facade aliases — was silently asserted
	// to be immutable, and the test failed for being out of date rather than for
	// finding anything.
	mutable := map[string]bool{}
	for _, o := range m.Objects {
		if !o.Immutable {
			mutable[o.Path] = true
		}
	}
	if len(mutable) == 0 {
		t.Fatal("expected at least one mutable pointer")
	}

	// Immutable objects carry ifGenerationMatch=0; mutable pointers don't.
	sawImmutable := false
	for name, igm := range f.requests {
		if mutable[name] {
			if igm != "" {
				t.Errorf("mutable %s sent ifGenerationMatch=%q, want none", name, igm)
			}
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
		if mutable[name] {
			if cacheControl != "no-store" {
				t.Errorf("mutable %s Cache-Control = %q, want no-store", name, cacheControl)
			}
			continue
		}
		if cacheControl != "public, max-age=31536000, immutable" {
			t.Errorf("immutable %s Cache-Control = %q", name, cacheControl)
		}
	}
}

func TestPublish_JSONUploadsGzipEncodedTarballsPlain(t *testing.T) {
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

	plain, err := os.ReadFile(filepath.Join(dir, "v1", "catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	if got := f.encoding["v1/catalog.json"]; got != "gzip" {
		t.Fatalf("catalog.json Content-Encoding = %q, want gzip", got)
	}
	zr, err := gzip.NewReader(bytes.NewReader(f.stored["v1/catalog.json"]))
	if err != nil {
		t.Fatalf("stored catalog.json is not gzip: %v", err)
	}
	unzipped, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(unzipped, plain) {
		t.Error("gunzipped upload does not match the plain dist catalog bytes")
	}

	m := readManifest(t, dir)
	for _, obj := range m.Objects {
		if obj.ContentType != contentTypeGzip {
			continue
		}
		// A tarball is already gzip content; an encoding layer would let GCS
		// transcode it on download and break content-hash pinning.
		if got := f.encoding[obj.Path]; got != "" {
			t.Errorf("tarball %s Content-Encoding = %q, want none", obj.Path, got)
		}
		disk, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(obj.Path)))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(f.stored[obj.Path], disk) {
			t.Errorf("tarball %s uploaded bytes differ from dist bytes", obj.Path)
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

	// And the catalog pointer uploads last of all: it is the release-completion
	// marker CI's drift probe byte-compares, so a publish that dies earlier
	// (e.g. before suggest.json) must still read as unpublished and be retried.
	if last := f.order[len(f.order)-1]; last != "v1/catalog.json" {
		t.Errorf("last uploaded object = %s, want the v1/catalog.json completion marker", last)
	}
}

func TestPublish_ExistingImmutableIsSkipped(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	// A schema object already exists with the expected bytes: the publisher
	// verifies it before treating the precondition failure as idempotent.
	const name = "v1/schemas/catalog.v6.schema.json"
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

// A private bucket answers the collision read with 401, and before the retry
// every second publish to one failed at exactly this path (RC-L).
func TestPublish_ExistingImmutableOnPrivateBucketRetriesWithCredentials(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	f.privateReads = true
	const name = "v1/schemas/catalog.v7.schema.json"
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
		t.Fatalf("Publish should verify a private bucket's existing object with its credential: %v", err)
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
	if got := f.readAuth[name]; got != "Bearer tok" {
		t.Errorf("private collision verification Authorization = %q, want the publisher token", got)
	}
}

func TestPublish_ExistingImmutableWithDifferentBytesFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v6.schema.json"
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
	assertMutablePointersUntouched(t, f, dir)
}

func TestPublish_ExistingImmutableThatCannotBeReadFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v6.schema.json"
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
	assertMutablePointersUntouched(t, f, dir)
}

func TestPublish_OversizedExistingImmutableFails(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	const name = "v1/schemas/catalog.v6.schema.json"
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
	assertMutablePointersUntouched(t, f, dir)
}

func assertMutablePointersUntouched(t *testing.T, f *fakeGCS, dir string) {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, object := range readManifest(t, dir).Objects {
		if object.Immutable {
			continue
		}
		if _, ok := f.requests[object.Path]; ok {
			t.Errorf("mutable pointer %s was published after immutable verification failed", object.Path)
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

func TestPutObject_HTTPFailures(t *testing.T) {
	const (
		token      = "publisher-secret-token"
		objectPath = "v1/catalog.json"
		refresh    = "GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)"
	)
	tests := []struct {
		name        string
		status      int
		body        string
		wantRefresh bool
	}{
		{
			name:        "expired token",
			status:      http.StatusUnauthorized,
			body:        `{"error":{"message":"Invalid Credentials"}}`,
			wantRefresh: true,
		},
		{
			name:        "forbidden token",
			status:      http.StatusForbidden,
			body:        `{"error":{"message":"Request had invalid authentication credentials."}}`,
			wantRefresh: true,
		},
		{
			name:   "server error",
			status: http.StatusInternalServerError,
			body:   `{"error":{"message":"backend unavailable"}}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.Header.Get("Authorization"); got != "Bearer "+token {
					t.Errorf("Authorization = %q, want bearer token", got)
				}
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			t.Cleanup(srv.Close)

			_, err := putObject(context.Background(), srv.Client(), srv.URL, token, "test-bucket", Object{
				Path:        objectPath,
				ContentType: "application/json",
			}, []byte(`{}`))
			if err == nil {
				t.Fatal("putObject error = nil, want HTTP failure")
			}
			got := err.Error()
			wantContext := fmt.Sprintf("catalog: upload %s: HTTP %d: %s", objectPath, tt.status, tt.body)
			if !strings.Contains(got, wantContext) {
				t.Errorf("error = %q, want context %q", got, wantContext)
			}
			if strings.Contains(got, token) {
				t.Errorf("error leaked publisher token: %q", got)
			}
			if gotRefresh := strings.Contains(got, refresh); gotRefresh != tt.wantRefresh {
				t.Errorf("error contains refresh command = %v, want %v: %q", gotRefresh, tt.wantRefresh, got)
			}
		})
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
