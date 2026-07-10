package catalog

import (
	"context"
	"net/http"
	"net/http/httptest"
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

// fakeGCS records upload requests and lets a test choose the status per
// object path (default 200).
type fakeGCS struct {
	mu       sync.Mutex
	requests map[string]string // object name -> ifGenerationMatch value ("" if absent)
	auth     map[string]string // object name -> Authorization header
	status   map[string]int    // object name -> forced status
}

func newFakeGCS() *fakeGCS {
	return &fakeGCS{
		requests: map[string]string{},
		auth:     map[string]string{},
		status:   map[string]int{},
	}
}

func (f *fakeGCS) server(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		f.mu.Lock()
		f.requests[name] = r.URL.Query().Get("ifGenerationMatch")
		f.auth[name] = r.Header.Get("Authorization")
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
}

func TestPublish_ExistingImmutableIsSkipped(t *testing.T) {
	dir := buildTree(t)
	f := newFakeGCS()
	// A schema object already exists → 412, must be skipped, not an error.
	f.status["v1/schemas/catalog.schema.json"] = http.StatusPreconditionFailed
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
		if s == "v1/schemas/catalog.schema.json" {
			found = true
		}
	}
	if !found {
		t.Errorf("existing immutable object not reported as skipped: %v", res.Skipped)
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
