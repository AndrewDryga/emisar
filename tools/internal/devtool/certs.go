package devtool

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const certFormat = "2\n"

func certificate(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("%s is not a PEM certificate", path)
	}
	return x509.ParseCertificate(block.Bytes)
}

func privateKey(path string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("%s is not a PEM private key", path)
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		if legacy, legacyErr := x509.ParsePKCS1PrivateKey(block.Bytes); legacyErr == nil {
			return legacy, nil
		}
		return nil, err
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s is not an RSA private key", path)
	}
	return rsaKey, nil
}

func serialNumber() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, limit)
}

func encodePrivateKey(key *rsa.PrivateKey) ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// The CA key stays owner-only; the leaf key is bind mounted into Keycloak,
// which runs as a non-root user and fails to start with AccessDeniedException
// on a 0600 file wherever container uids are not remapped (Linux CI, and any
// native-Docker host). It is a regenerable, workspace-scoped, localhost-only
// development key — the CA that signs it is what stays private.
func writeKeyPair(dir, name string, key *rsa.PrivateKey, der []byte) error {
	keyPEM, err := encodePrivateKey(key)
	if err != nil {
		return err
	}
	keyMode := os.FileMode(0o600)
	if name == "tls" {
		keyMode = 0o644
	}
	if err := atomicWrite(filepath.Join(dir, name+".key"), keyPEM, keyMode); err != nil {
		return err
	}
	return atomicWrite(filepath.Join(dir, name+".crt"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
}

func generateCA(dir string, now time.Time) (*x509.Certificate, *rsa.PrivateKey, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}
	serial, err := serialNumber()
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "emisar dev CA"},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(3650 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		SubjectKeyId:          publicKeyID(&key.PublicKey),
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	if err := writeKeyPair(dir, "ca", key, der); err != nil {
		return nil, nil, err
	}
	cert, err := x509.ParseCertificate(der)
	return cert, key, err
}

func generateLeaf(dir string, ca *x509.Certificate, caKey *rsa.PrivateKey, now time.Time) error {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return err
	}
	serial, err := serialNumber()
	if err != nil {
		return err
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "keycloak"},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(397 * 24 * time.Hour),
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		SubjectKeyId:          publicKeyID(&key.PublicKey),
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	return writeKeyPair(dir, "tls", key, der)
}

func publicKeyID(key *rsa.PublicKey) []byte {
	der, _ := x509.MarshalPKIXPublicKey(key)
	hash := sha256.Sum256(der)
	return hash[:]
}

func validLeafCertificate(dir string, ca *x509.Certificate, now time.Time) bool {
	format, err := os.ReadFile(filepath.Join(dir, "format"))
	if err != nil || string(format) != certFormat {
		return false
	}
	leaf, err := certificate(filepath.Join(dir, "tls.crt"))
	if err != nil || leaf.NotAfter.Before(now.Add(30*24*time.Hour)) {
		return false
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	_, err = leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "localhost", KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, CurrentTime: now})
	return err == nil
}

func validLeaf(dir string, ca *x509.Certificate, now time.Time) bool {
	if !validLeafCertificate(dir, ca, now) {
		return false
	}
	leaf, err := certificate(filepath.Join(dir, "tls.crt"))
	if err != nil {
		return false
	}
	key, err := privateKey(filepath.Join(dir, "tls.key"))
	if err != nil {
		return false
	}
	publicKey, ok := leaf.PublicKey.(*rsa.PublicKey)
	return ok && publicKey.Equal(&key.PublicKey)
}

func (a *App) generateCertificates(rotate bool) error {
	if a.inBox() {
		return fmt.Errorf("generate or rotate development certificates on the host")
	}
	before := ""
	if leaf, err := certificate(filepath.Join(a.Certs, "tls.crt")); err == nil {
		before = hex.EncodeToString(leaf.Raw)
	}
	if rotate {
		if err := os.RemoveAll(a.Certs); err != nil {
			return err
		}
	}
	// 0755, not 0700. This directory is bind mounted into Keycloak, which runs as a
	// non-root user: with the directory unreadable it cannot TRAVERSE to the certs,
	// even though the leaf and its key are world-readable. Keycloak does not fail on
	// that — it starts HTTP-only, so the OIDC leg of `./run e2e sso` connects to a
	// port with no TLS listener and reports a TLS-trust failure that is really a
	// permission one. The private keys keep their own 0600.
	if err := os.MkdirAll(a.Certs, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(a.Certs, 0o755); err != nil {
		return err
	}

	now := time.Now()
	ca, caKey, err := loadCA(a.Certs)
	if err != nil {
		ca, caKey, err = generateCA(a.Certs, now)
		if err != nil {
			return fmt.Errorf("generating development CA: %w", err)
		}
	}
	if !validLeaf(a.Certs, ca, now) {
		if err := generateLeaf(a.Certs, ca, caKey, now); err != nil {
			return fmt.Errorf("generating Keycloak certificate: %w", err)
		}
	}
	// A leaf generated before the mode split (or restored from a cache) is
	// still 0600, which Keycloak cannot read; correct it every run.
	if err := os.Chmod(filepath.Join(a.Certs, "tls.key"), 0o644); err != nil {
		return err
	}
	if err := atomicWrite(filepath.Join(a.Certs, "format"), []byte(certFormat), 0o600); err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(a.Certs, "ca.srl"))
	leaf, err := certificate(filepath.Join(a.Certs, "tls.crt"))
	if err != nil {
		return err
	}
	if !validLeaf(a.Certs, ca, now) {
		return fmt.Errorf("generated Keycloak certificate did not verify")
	}
	a.certsChanged = before == "" || before != hex.EncodeToString(leaf.Raw)
	fmt.Fprintln(a.Out, "Keycloak dev certificates ready (SAN: DNS:localhost, IP:127.0.0.1)")
	return nil
}

func loadCA(dir string) (*x509.Certificate, *rsa.PrivateKey, error) {
	cert, err := certificate(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return nil, nil, err
	}
	key, err := privateKey(filepath.Join(dir, "ca.key"))
	if err != nil {
		return nil, nil, err
	}
	if !cert.IsCA || cert.KeyUsage&x509.KeyUsageCertSign == 0 {
		return nil, nil, fmt.Errorf("development CA is not a signing CA")
	}
	publicKey, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, nil, fmt.Errorf("development CA certificate does not contain an RSA key")
	}
	if !publicKey.Equal(&key.PublicKey) {
		return nil, nil, fmt.Errorf("development CA key does not match its certificate")
	}
	return cert, key, nil
}

// caBundle locates the trust store Erlang reads. Its contents are the platform's
// system roots plus the workspace CA, so the host and a box produce different
// correct files — sharing one path through the repo mount makes each overwrite
// the other's roots, and leaves a read-only box unable to run anything. Box
// artifacts belong in the box cache, the same reason MIX_BUILD_ROOT lives there.
func (a *App) caBundle() string {
	if !a.inBox() {
		return filepath.Join(a.Certs, "ca-bundle.crt")
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return filepath.Join(a.Certs, "ca-bundle.crt")
	}
	return filepath.Join(cache, "emisar", "ca-bundle.crt")
}

func (a *App) makeCABundle(ctx context.Context) error {
	ca, err := os.ReadFile(filepath.Join(a.Certs, "ca.crt"))
	if err != nil {
		return fmt.Errorf("the Keycloak CA is missing; run ./run certs")
	}
	var system []byte
	if runtime.GOOS == "darwin" {
		system, err = a.output(ctx, a.Root, nil, "security", "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain")
	} else {
		system, err = os.ReadFile("/etc/ssl/certs/ca-certificates.crt")
	}
	if err != nil {
		return fmt.Errorf("locating system CA bundle: %w", err)
	}
	system = append(system, '\n')
	system = append(system, ca...)
	bundle := a.caBundle()
	// Same directory, same reason as above: a non-root container has to traverse it.
	if err := os.MkdirAll(filepath.Dir(bundle), 0o755); err != nil {
		return err
	}
	return atomicWrite(bundle, system, 0o644)
}

func (a *App) refreshServicesForCertificate(ctx context.Context) error {
	if !a.certsChanged {
		return nil
	}
	fmt.Fprintln(a.Out, "recreating dependency services after Keycloak certificate change")
	if err := a.run(ctx, a.Root, nil, "coop", "down"); err != nil {
		return err
	}
	return a.run(ctx, a.Root, nil, "coop", "up")
}

func certFingerprint(cert *x509.Certificate) string {
	hash := sha256.Sum256(cert.Raw)
	return strings.ToUpper(hex.EncodeToString(hash[:]))
}

func (a *App) caFingerprint() (string, error) {
	cert, err := certificate(filepath.Join(a.Certs, "ca.crt"))
	if err != nil {
		return "", fmt.Errorf("the Keycloak CA is missing; run ./run certs")
	}
	return certFingerprint(cert), nil
}

func (a *App) tlsSPKI() (string, error) {
	cert, err := certificate(filepath.Join(a.Certs, "tls.crt"))
	if err != nil {
		return "", fmt.Errorf("the Keycloak certificate is missing; run ./run certs on the host")
	}
	hash := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	encoded := base64.StdEncoding.EncodeToString(hash[:])
	if len(encoded) != 44 || !strings.HasSuffix(encoded, "=") {
		return "", fmt.Errorf("could not derive Keycloak certificate SPKI")
	}
	return encoded, nil
}

func (a *App) requireMacHost() error {
	if a.inBox() {
		return fmt.Errorf("manage host browser trust from the host")
	}
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("host browser trust is currently supported on macOS only")
	}
	return nil
}

func (a *App) loginKeychain(ctx context.Context) (string, error) {
	data, err := a.output(ctx, a.Root, nil, "security", "default-keychain", "-d", "user")
	if err != nil {
		return "", err
	}
	return strings.Trim(strings.TrimSpace(string(data)), "\""), nil
}

func (a *App) certInstalled(ctx context.Context) (bool, error) {
	fingerprint, err := a.caFingerprint()
	if err != nil {
		return false, err
	}
	keychain, err := a.loginKeychain(ctx)
	if err != nil {
		return false, err
	}
	data, _ := a.output(ctx, a.Root, nil, "security", "find-certificate", "-a", "-Z", "-c", "emisar dev CA", keychain)
	return strings.Contains(string(data), "SHA-256 hash: "+fingerprint), nil
}

func (a *App) certTrusted(ctx context.Context) (bool, error) {
	installed, err := a.certInstalled(ctx)
	if err != nil || !installed {
		return false, err
	}
	_, err = a.output(ctx, a.Root, nil, "security", "verify-cert", "-q", "-c", filepath.Join(a.Certs, "tls.crt"), "-p", "ssl", "-s", "localhost", "-L")
	return err == nil, nil
}

func (a *App) trustCertificate(ctx context.Context) error {
	if err := a.requireMacHost(); err != nil {
		return err
	}
	if err := a.generateCertificates(false); err != nil {
		return err
	}
	if err := a.refreshServicesForCertificate(ctx); err != nil {
		return err
	}
	trusted, _ := a.certTrusted(ctx)
	if trusted {
		fmt.Fprintln(a.Out, "Keycloak dev CA already trusted for https://localhost")
		return nil
	}
	keychain, err := a.loginKeychain(ctx)
	if err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-s", "localhost", "-k", keychain, filepath.Join(a.Certs, "ca.crt")); err != nil {
		return err
	}
	trusted, _ = a.certTrusted(ctx)
	if !trusted {
		return fmt.Errorf("macOS did not trust the Keycloak dev CA")
	}
	fmt.Fprintf(a.Out, "trusted Keycloak dev CA for https://localhost in %s\n", keychain)
	return nil
}

func (a *App) untrustCertificate(ctx context.Context) error {
	if err := a.requireMacHost(); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(a.Certs, "ca.crt")); os.IsNotExist(err) {
		fmt.Fprintln(a.Out, "Keycloak dev CA is not generated")
		return nil
	}
	installed, err := a.certInstalled(ctx)
	if err != nil {
		return err
	}
	if !installed {
		fmt.Fprintln(a.Out, "Keycloak dev CA is not installed in the user keychain")
		return nil
	}
	fingerprint, _ := a.caFingerprint()
	keychain, err := a.loginKeychain(ctx)
	if err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "security", "delete-certificate", "-t", "-Z", fingerprint, keychain); err != nil {
		return err
	}
	installed, _ = a.certInstalled(ctx)
	if installed {
		return fmt.Errorf("could not remove Keycloak dev CA %s from %s", fingerprint, keychain)
	}
	fmt.Fprintf(a.Out, "removed Keycloak dev CA %s from %s\n", fingerprint, keychain)
	return nil
}

func (a *App) certificateStatus(ctx context.Context) error {
	if err := a.requireMacHost(); err != nil {
		return err
	}
	trusted, _ := a.certTrusted(ctx)
	if !trusted {
		return fmt.Errorf("not trusted; run: ./run certs trust")
	}
	fingerprint, _ := a.caFingerprint()
	fmt.Fprintf(a.Out, "trusted for https://localhost (%s)\n", fingerprint)
	return nil
}

func (a *App) rotateCertificates(ctx context.Context) error {
	if a.inBox() {
		return fmt.Errorf("generate or rotate development certificates on the host")
	}
	restore := false
	if runtime.GOOS == "darwin" {
		var err error
		restore, err = a.certInstalled(ctx)
		if err != nil {
			return err
		}
		if restore {
			if err := a.untrustCertificate(ctx); err != nil {
				return err
			}
		}
	}
	if err := a.generateCertificates(true); err != nil {
		return err
	}
	if err := a.refreshServicesForCertificate(ctx); err != nil {
		return err
	}
	if restore {
		return a.trustCertificate(ctx)
	}
	return nil
}

func (a *App) certsCommand(ctx context.Context, args []string) error {
	if len(args) > 1 {
		return usage("usage: ./run certs [rotate|trust|untrust|status]")
	}
	if len(args) == 0 {
		if err := a.generateCertificates(false); err != nil {
			return err
		}
		return a.refreshServicesForCertificate(ctx)
	}
	switch args[0] {
	// `./run help` documents `rotate`, and every sibling subcommand is a bare
	// word — `--rotate` was the only flag-shaped one in the whole surface, so
	// the documented spelling errored out. Keep the flag for saved commands.
	case "rotate", "--rotate":
		return a.rotateCertificates(ctx)
	case "trust":
		return a.trustCertificate(ctx)
	case "untrust":
		return a.untrustCertificate(ctx)
	case "status":
		return a.certificateStatus(ctx)
	default:
		return usage("usage: ./run certs [rotate|trust|untrust|status]")
	}
}
