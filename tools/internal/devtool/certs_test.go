package devtool

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testApp(t *testing.T) *App {
	t.Helper()
	t.Setenv("COOP_BOX", "")
	t.Setenv("COOP_SERVE_URL_4000", "")
	root := t.TempDir()
	app := New(root, bytes.NewBuffer(nil), &bytes.Buffer{}, &bytes.Buffer{})
	app.Certs = filepath.Join(root, "certs")
	return app
}

func TestGenerateCertificatesIsValidIdempotentAndRotatable(t *testing.T) {
	app := testApp(t)
	if err := app.generateCertificates(false); err != nil {
		t.Fatal(err)
	}
	caBefore, err := certificate(filepath.Join(app.Certs, "ca.crt"))
	if err != nil {
		t.Fatal(err)
	}
	leafBefore, err := certificate(filepath.Join(app.Certs, "tls.crt"))
	if err != nil {
		t.Fatal(err)
	}
	if !caBefore.IsCA || caBefore.KeyUsage&x509.KeyUsageCertSign == 0 {
		t.Fatal("generated CA lacks signing constraints")
	}
	if err := leafBefore.VerifyHostname("localhost"); err != nil {
		t.Fatalf("localhost SAN: %v", err)
	}
	if err := leafBefore.VerifyHostname("127.0.0.1"); err != nil {
		t.Fatalf("loopback SAN: %v", err)
	}
	remaining := time.Until(leafBefore.NotAfter)
	if remaining < 396*24*time.Hour || remaining > 398*24*time.Hour {
		t.Fatalf("leaf validity = %v, want about 397 days", remaining)
	}
	for _, file := range []struct {
		name string
		mode os.FileMode
		// The CA key is the one that must stay private. The leaf key is bind
		// mounted into Keycloak, which runs as a non-root user and refuses to
		// start on a 0600 file wherever container uids are not remapped.
	}{{"ca.key", 0o600}, {"tls.key", 0o644}, {"format", 0o600}, {"ca.crt", 0o644}, {"tls.crt", 0o644}} {
		info, err := os.Stat(filepath.Join(app.Certs, file.name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != file.mode {
			t.Fatalf("%s mode = %v, want %v", file.name, info.Mode().Perm(), file.mode)
		}
	}

	if err := app.generateCertificates(false); err != nil {
		t.Fatal(err)
	}
	leafSame, _ := certificate(filepath.Join(app.Certs, "tls.crt"))
	if certFingerprint(leafSame) != certFingerprint(leafBefore) || app.certsChanged {
		t.Fatal("idempotent generation changed the leaf")
	}
	if err := app.generateCertificates(true); err != nil {
		t.Fatal(err)
	}
	caRotated, _ := certificate(filepath.Join(app.Certs, "ca.crt"))
	leafRotated, _ := certificate(filepath.Join(app.Certs, "tls.crt"))
	if certFingerprint(caRotated) == certFingerprint(caBefore) || certFingerprint(leafRotated) == certFingerprint(leafBefore) || !app.certsChanged {
		t.Fatal("rotation retained old certificate material")
	}

	if err := os.Remove(filepath.Join(app.Certs, "ca.key")); err != nil {
		t.Fatal(err)
	}
	if err := app.generateCertificates(false); err != nil {
		t.Fatal(err)
	}
	caRepaired, _ := certificate(filepath.Join(app.Certs, "ca.crt"))
	leafRepaired, _ := certificate(filepath.Join(app.Certs, "tls.crt"))
	if certFingerprint(caRepaired) == certFingerprint(caRotated) || certFingerprint(leafRepaired) == certFingerprint(leafRotated) {
		t.Fatal("missing CA material did not replace the CA and leaf")
	}

	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM, err := encodePrivateKey(otherKey)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(app.Certs, "tls.key"), keyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.generateCertificates(false); err != nil {
		t.Fatal(err)
	}
	leafAfterMismatch, _ := certificate(filepath.Join(app.Certs, "tls.crt"))
	if certFingerprint(leafAfterMismatch) == certFingerprint(leafRepaired) {
		t.Fatal("mismatched leaf key did not replace the certificate pair")
	}
}

func TestTLSSPKIIsOneBase64SHA256(t *testing.T) {
	app := testApp(t)
	if err := app.generateCertificates(false); err != nil {
		t.Fatal(err)
	}
	spki, err := app.tlsSPKI()
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.StdEncoding.DecodeString(spki)
	if err != nil || len(decoded) != 32 {
		t.Fatalf("SPKI = %q, decoded=%d, err=%v", spki, len(decoded), err)
	}
}

func TestCABundleKeepsBoxCopyOutOfTheRepo(t *testing.T) {
	app := testApp(t)
	host := app.caBundle()
	if host != filepath.Join(app.Certs, "ca-bundle.crt") {
		t.Fatalf("host bundle = %q, want it beside the workspace CA", host)
	}

	// The box writes different system roots into the same mounted path, so the
	// two must never resolve to one file.
	t.Setenv("COOP_BOX", "1")
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	box := app.caBundle()
	if box == host {
		t.Fatalf("box bundle = %q, want a path outside the repo mount", box)
	}
	if strings.HasPrefix(box, app.Root) {
		t.Fatalf("box bundle = %q, want it outside the repo root %q", box, app.Root)
	}
}
