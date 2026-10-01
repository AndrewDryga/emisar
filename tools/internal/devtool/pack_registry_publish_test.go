package devtool

import (
	"net/http"
	"net/http/httptest"
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
