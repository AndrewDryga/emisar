package httpsecurity

import (
	"crypto/tls"
	"net/http"
	"testing"
)

func TestClientWithTLS12SetsExplicitMinimum(t *testing.T) {
	client := ClientWithTLS12(&http.Client{})
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http.Transport", client.Transport)
	}
	if got := transport.TLSClientConfig.MinVersion; got != tls.VersionTLS12 {
		t.Fatalf("TLS minimum = %v, want %v", got, tls.VersionTLS12)
	}
}
