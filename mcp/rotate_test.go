package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestKeyPrefix(t *testing.T) {
	cases := []struct {
		name string
		key  string
		want string
	}{
		{"full key truncates to emk- plus 12", "emk-abcdefgh1234SECRETPART", "emk-abcdefgh1234"},
		{"exactly prefix-length stays whole", "emk-abcdefgh1234", "emk-abcdefgh1234"},
		{"short key stays whole", "emk-short", "emk-short"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := keyPrefix(tc.key); got != tc.want {
				t.Fatalf("keyPrefix(%q) = %q, want %q", tc.key, got, tc.want)
			}
		})
	}
}

func TestValidSuccessor(t *testing.T) {
	cases := []struct {
		name string
		s    string
		want bool
	}{
		{"real-shaped key", "emk-abcdefgh1234abcdefgh1234", true},
		{"wrong prefix", "emo-abcdefgh1234abcdefgh1234", false},
		{"too short", "emk-abc", false},
		{"way too long", "emk-" + string(make([]byte, 300)), false},
		{"empty", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validSuccessor(tc.s); got != tc.want {
				t.Fatalf("validSuccessor(%q) = %v, want %v", tc.s, got, tc.want)
			}
		})
	}
}

func TestPersistAndLoadSuccessor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "emisar", "credentials.json")
	bootstrap := "emk-abcdefgh1234"
	secret := "emk-newsecretnewsecret9999"

	if err := persistSuccessor(path, bootstrap, secret); err != nil {
		t.Fatalf("persistSuccessor: %v", err)
	}

	got, ok := loadStoredSuccessor(path, bootstrap)
	if !ok || got != secret {
		t.Fatalf("loadStoredSuccessor = (%q, %v), want (%q, true)", got, ok, secret)
	}

	// A second rotation under the SAME bootstrap prefix replaces the entry —
	// the chain always resolves bootstrap → current.
	next := "emk-evennewersecret0000"
	if err := persistSuccessor(path, bootstrap, next); err != nil {
		t.Fatalf("persistSuccessor (second): %v", err)
	}
	if got, _ := loadStoredSuccessor(path, bootstrap); got != next {
		t.Fatalf("after re-rotation loadStoredSuccessor = %q, want %q", got, next)
	}

	// The file stores live secrets — owner-only on POSIX.
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		if perm := info.Mode().Perm(); perm&0o077 != 0 {
			t.Fatalf("credentials file mode %v is group/world accessible", perm)
		}
	}
}

func TestLoadStoredSuccessor_IgnoresMissingCorruptAndInvalid(t *testing.T) {
	dir := t.TempDir()

	if _, ok := loadStoredSuccessor("", "emk-x"); ok {
		t.Fatal("empty path must not resolve a successor")
	}
	if _, ok := loadStoredSuccessor(filepath.Join(dir, "absent.json"), "emk-x"); ok {
		t.Fatal("missing file must not resolve a successor")
	}

	corrupt := filepath.Join(dir, "corrupt.json")
	if err := os.WriteFile(corrupt, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := loadStoredSuccessor(corrupt, "emk-x"); ok {
		t.Fatal("corrupt file must not resolve a successor")
	}

	invalid := filepath.Join(dir, "invalid.json")
	if err := os.WriteFile(invalid, []byte(`{"emk-x":"not-a-key"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := loadStoredSuccessor(invalid, "emk-x"); ok {
		t.Fatal("an invalid stored value must not be adopted")
	}
}

func TestForward_AdoptsSuccessorFromHeaderAndPersists(t *testing.T) {
	t.Parallel()

	successor := "emk-successorsuccessor11"
	var sawAuth []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = append(sawAuth, r.Header.Get("Authorization"))
		if len(sawAuth) == 1 {
			w.Header().Set(successorKeyHeader, successor)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}`))
	}))
	defer srv.Close()

	credsPath := filepath.Join(t.TempDir(), "emisar", "credentials.json")
	bootstrap := "emk-bootstrap123"

	b := &bridge{
		endpoint:        srv.URL,
		apiKey:          "emk-bootstrap123SECRET00",
		userAgent:       "emisar-mcp/test",
		client:          newHTTPClient(),
		sessionID:       "s",
		bootstrapPrefix: bootstrap,
		credsPath:       credsPath,
	}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if b.apiKey != successor {
		t.Fatalf("apiKey not swapped: %q", b.apiKey)
	}

	// The very next request rides the successor.
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":2,"method":"ping"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if want := "Bearer " + successor; sawAuth[1] != want {
		t.Fatalf("second request auth = %q, want %q", sawAuth[1], want)
	}

	// …and the swap survived to disk under the bootstrap prefix.
	if got, ok := loadStoredSuccessor(credsPath, bootstrap); !ok || got != successor {
		t.Fatalf("persisted successor = (%q, %v), want (%q, true)", got, ok, successor)
	}
}

func TestForward_IgnoresInvalidSuccessorHeader(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(successorKeyHeader, "definitely-not-a-key")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}`))
	}))
	defer srv.Close()

	original := "emk-bootstrap123SECRET00"

	b := &bridge{
		endpoint:  srv.URL,
		apiKey:    original,
		userAgent: "emisar-mcp/test",
		client:    newHTTPClient(),
		sessionID: "s",
	}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if b.apiKey != original {
		t.Fatalf("a malformed successor must not be adopted; apiKey = %q", b.apiKey)
	}
}
