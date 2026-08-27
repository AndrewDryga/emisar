package httpsecurity

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Three of the runner's five outbound clients shipped with no redirect policy
// at all, so they inherited Go's default and would have followed an https→http
// hop without comment. One of them fetches the release archive the runner then
// executes.
func TestRefuseDowngradeRedirects(t *testing.T) {
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("served over plaintext"))
	}))
	defer plain.Close()

	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/downgrade" {
			http.Redirect(w, r, plain.URL, http.StatusFound)
			return
		}
		http.Redirect(w, r, r.URL.String(), http.StatusFound)
	}))
	defer secure.Close()

	client := RefuseDowngradeRedirects(ClientWithTLS12(secure.Client()))

	t.Run("https to http is refused", func(t *testing.T) {
		resp, err := client.Get(secure.URL + "/downgrade")
		if err == nil {
			_ = resp.Body.Close()
			t.Fatal("an https→http redirect was followed")
		}
		if !strings.Contains(err.Error(), "downgrade") {
			t.Fatalf("error = %v, want an HTTPS-downgrade refusal", err)
		}
	})

	t.Run("a redirect chain is capped", func(t *testing.T) {
		resp, err := client.Get(secure.URL + "/loop")
		if err == nil {
			_ = resp.Body.Close()
			t.Fatal("an endless redirect chain was followed")
		}
		if !strings.Contains(err.Error(), "stopped after") {
			t.Fatalf("error = %v, want a hop-cap refusal", err)
		}
	})
}
