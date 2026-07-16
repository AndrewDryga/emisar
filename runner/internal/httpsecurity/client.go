// Package httpsecurity contains the shared transport hardening used by
// runner-runtime outbound HTTP clients.
package httpsecurity

import (
	"crypto/tls"
	"net/http"
)

// ClientWithTLS12 returns a shallow client copy whose standard HTTP transport
// requires TLS 1.2 or newer. Existing transport and TLS settings are cloned so
// caller-owned clients are not mutated and certificate behavior is preserved.
// Custom RoundTrippers are left untouched because they do not expose a
// configurable crypto/tls transport.
func ClientWithTLS12(base *http.Client) *http.Client {
	client := *base
	client.Transport = TransportWithTLS12(client.Transport)
	return &client
}

// TransportWithTLS12 returns a cloned standard transport with an explicit TLS
// 1.2 minimum. A stronger caller-configured minimum is preserved.
func TransportWithTLS12(base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}

	transport, ok := base.(*http.Transport)
	if !ok {
		return base
	}

	transport = transport.Clone()
	config := transport.TLSClientConfig
	if config == nil {
		config = &tls.Config{MinVersion: tls.VersionTLS12}
	} else {
		config = config.Clone()
	}
	if config.MinVersion < tls.VersionTLS12 {
		config.MinVersion = tls.VersionTLS12
	}
	transport.TLSClientConfig = config
	return transport
}
