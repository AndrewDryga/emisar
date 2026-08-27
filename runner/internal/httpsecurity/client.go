// Package httpsecurity contains the shared transport hardening used by
// runner-runtime outbound HTTP clients.
package httpsecurity

import (
	"crypto/tls"
	"errors"
	"fmt"
	"net/http"

	"github.com/andrewdryga/emisar/runner/internal/config"
)

// Go's own default is 10; naming it keeps the number out of the message format.
const maxRedirects = 10

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

// RefuseDowngradeRedirects installs the redirect policy every runner-runtime
// client wants: a hop cap, the same scheme check the configured endpoint had to
// pass, and a refusal to leave HTTPS once a chain has started on it. Without it
// a client inherits Go's default, which follows a 302 from https to http without
// comment — and these clients fetch packs, catalogs and the release archive the
// runner is about to execute.
//
// The client is mutated in place, so callers apply it to the copy
// ClientWithTLS12 already handed them.
func RefuseDowngradeRedirects(client *http.Client) *http.Client {
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= maxRedirects {
			return fmt.Errorf("stopped after %d redirects", maxRedirects)
		}
		if err := config.CheckEndpointScheme(req.URL.String(), false); err != nil {
			return fmt.Errorf("redirect refused: %w", err)
		}
		if len(via) > 0 && via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
			return errors.New("redirect refused HTTPS downgrade")
		}
		return nil
	}
	return client
}
