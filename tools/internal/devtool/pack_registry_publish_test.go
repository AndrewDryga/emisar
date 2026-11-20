package devtool

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The publish rehearsal treats three answers differently, each the way CD's
// publish job does: a catalog is the history to build against, a 404 is a
// missing pointer the publication restores, and anything else means the
// registry could not be read. That last one has to fail rather than fall back:
// an outage that rehearsed against the committed catalog would pass every time.
func TestPublishedPackCatalogSeparatesMissingFromUnreadable(t *testing.T) {
	const catalog = `{"schema_version":1,"packs":[]}`
	tests := []struct {
		name      string
		handler   http.HandlerFunc
		wantFound bool
		wantErr   string
	}{
		{
			name: "published catalog",
			handler: func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(catalog))
			},
			wantFound: true,
		},
		{
			name:    "missing pointer",
			handler: http.NotFound,
		},
		{
			name: "serving path broken",
			handler: func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusBadGateway)
			},
			wantErr: "502",
		},
		{
			// Followed, this would read as a published catalog.
			name: "redirect",
			handler: func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/elsewhere" {
					_, _ = w.Write([]byte(catalog))
					return
				}
				http.Redirect(w, r, "/elsewhere", http.StatusFound)
			},
			wantErr: "302",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(test.handler)
			defer server.Close()

			body, found, err := publishedPackCatalog(t.Context(), server.URL+"/v1/catalog.json")
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("error = %v, want one naming %s", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if found != test.wantFound {
				t.Fatalf("found = %v, want %v", found, test.wantFound)
			}
			if found && string(body) != catalog {
				t.Fatalf("catalog = %q, want %q", body, catalog)
			}
		})
	}
}

// `pack sync` regenerates the committed catalog against the same history the
// publish rehearsal reads, so it chooses that history the same way: a valid
// published catalog, else the committed one when the registry has none or
// packctl rejects it, and never a fallback when the registry cannot be read.
func TestPackSyncPreviousChoosesTheRehearsalsHistory(t *testing.T) {
	const catalog = `{"schema_version":1,"packs":[]}`
	tests := []struct {
		name          string
		handler       http.HandlerFunc
		wantCommitted bool
		wantErr       string
	}{
		{
			name:    "published catalog",
			handler: func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(catalog)) },
		},
		{name: "missing catalog", handler: http.NotFound, wantCommitted: true},
		{
			name:          "malformed catalog",
			handler:       func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("malformed")) },
			wantCommitted: true,
		},
		{
			name:    "unreadable registry",
			handler: func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusBadGateway) },
			wantErr: "502",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			app := testApp(t)
			bin := filepath.Join(app.Root, "bin")
			if err := os.MkdirAll(bin, 0o755); err != nil {
				t.Fatal(err)
			}
			// The stub rejects exactly the malformed body, standing in for
			// `packctl catalog validate`.
			packctl := "#!/bin/sh\n[ \"$1 $2\" = 'catalog validate' ] || exit 99\n! grep -q malformed \"$3\"\n"
			if err := os.WriteFile(filepath.Join(bin, "packctl"), []byte(packctl), 0o755); err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(test.handler)
			defer server.Close()

			previous, err := app.packSyncPrevious(t.Context(), server.URL+"/v1/catalog.json", t.TempDir())
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("error = %v, want one naming %s", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			committed := filepath.Join(app.Portal, "apps", "emisar", "priv", "packs", "catalog.json")
			if test.wantCommitted {
				if previous != committed {
					t.Fatalf("previous = %s, want the committed catalog %s", previous, committed)
				}
				return
			}
			data, err := os.ReadFile(previous)
			if err != nil {
				t.Fatal(err)
			}
			if string(data) != catalog {
				t.Fatalf("previous holds %q, want the published catalog", data)
			}
		})
	}
}
