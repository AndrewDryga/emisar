package signing

import (
	"encoding/base64"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
)

// TestVerifiesCertificateFromAnIndependentIssuer is the proof behind "issue
// these from your own PKI". Everything else in this package mints certificates
// with Go's crypto/x509 — the same library the verifier parses them with — so a
// Go-only test cannot tell a standard certificate from one that merely
// round-trips through one implementation.
//
// OpenSSL is a genuinely independent ASN.1 encoder, so a certificate it issues
// exercises the claim a customer PKI actually makes: Vault, AD CS, and step-ca
// all emit standard DER, not Go's. If this passes, the profile is expressible
// in ordinary X.509 tooling; if the SAN encoding or the profile checks ever
// drift toward something only Go produces, this is what fails.
func TestVerifiesCertificateFromAnIndependentIssuer(t *testing.T) {
	openssl, err := exec.LookPath("openssl")
	if err != nil {
		t.Skip("openssl is not installed; CI runners provide it")
	}

	dir := t.TempDir()
	path := func(name string) string { return filepath.Join(dir, name) }
	run := func(args ...string) {
		t.Helper()
		output, err := exec.Command(openssl, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("openssl %v: %v\n%s", args, err, output)
		}
	}

	// An offline CA, exactly as `emisar signing new-ca` describes one.
	run("genpkey", "-algorithm", "ED25519", "-out", path("ca.key"))
	run("req", "-x509", "-new", "-key", path("ca.key"), "-days", "365",
		"-subj", "/CN=independent-ca", "-out", path("ca.crt"),
		"-addext", "basicConstraints=critical,CA:TRUE",
		"-addext", "keyUsage=critical,keyCertSign")

	// A dispatch-signing leaf carrying the emisar scope SAN.
	run("genpkey", "-algorithm", "ED25519", "-out", path("leaf.key"))
	run("req", "-new", "-key", path("leaf.key"), "-subj", "/CN=operator", "-out", path("leaf.csr"))

	scopeURI, err := attest.EncodeScopeURI(attest.Scope{
		Group:  "prod",
		Labels: map[string]string{"env": "prod"},
	})
	if err != nil {
		t.Fatalf("EncodeScopeURI: %v", err)
	}
	extensions := "basicConstraints=critical,CA:FALSE\n" +
		"keyUsage=critical,digitalSignature\n" +
		"subjectAltName=URI:" + scopeURI + "\n"
	if err := os.WriteFile(path("leaf.ext"), []byte(extensions), 0o600); err != nil {
		t.Fatalf("write extensions: %v", err)
	}
	run("x509", "-req", "-in", path("leaf.csr"), "-CA", path("ca.crt"), "-CAkey", path("ca.key"),
		"-out", path("leaf.crt"), "-days", "1", "-extfile", path("leaf.ext"))

	caPEM, err := os.ReadFile(path("ca.crt"))
	if err != nil {
		t.Fatalf("read CA: %v", err)
	}
	leafDER := derFromPEMFile(t, path("leaf.crt"))

	// The runner accepts it: the chain verifies to the configured anchor, the
	// profile holds, and the scope parses back to what OpenSSL was asked to
	// encode.
	verifier, err := NewVerifier(true, []CAConfig{{Name: "independent", PEM: string(caPEM)}},
		time.Hour, testRunnerID, testOrigin, "prod", map[string]string{"env": "prod"},
		NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier with an OpenSSL-issued anchor: %v", err)
	}

	chain, err := decodeCertChain([]string{base64.StdEncoding.EncodeToString(leafDER)})
	if err != nil {
		t.Fatalf("decodeCertChain: %v", err)
	}
	_, scope, err := attest.VerifyChain(verifier.roots, chain, time.Now())
	if err != nil {
		t.Fatalf("an OpenSSL-issued certificate must verify: %v", err)
	}
	if scope.Group != "prod" || scope.Labels["env"] != "prod" {
		t.Fatalf("scope from an independent issuer = %+v, want group=prod env=prod", scope)
	}
	if !scope.Matches("prod", map[string]string{"env": "prod"}) {
		t.Fatal("the scope must match the runner it was issued for")
	}
}

func derFromPEMFile(t *testing.T, path string) []byte {
	t.Helper()
	pemText, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	block, _ := pem.Decode(pemText)
	if block == nil || block.Type != "CERTIFICATE" {
		t.Fatalf("%s holds no PEM CERTIFICATE block", path)
	}
	return block.Bytes
}
