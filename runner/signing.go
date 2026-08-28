package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/attest"
)

// The signing CLI is OFFLINE by design: every key it mints is printed locally
// and sent nowhere. The CA private key in particular must stay offline/
// customer-held — the whole threat model is that a compromised control plane can
// RELAY a certified dispatch but never MINT one, so nothing here writes a CA key
// anywhere the portal can reach.
//
// Certificates are X.509 under the emisar profile, so a customer PKI (Vault,
// AD CS, step-ca, an HSM-backed CA) can issue them instead of this CLI. This
// CLI is the self-serve path: it does not mint intermediates and cannot sign
// with an HSM-held key — a customer who needs either issues from their own PKI.

// signingKeyAlg is the leaf/CA key algorithm. Ed25519 is the default; ECDSA
// P-256 exists because several major KMS and HSM products still do not offer
// Ed25519, and CA custody in an HSM is a first-class case for a customer PKI.
type signingKeyAlg string

const (
	algEd25519 signingKeyAlg = "ed25519"
	algP256    signingKeyAlg = "p256"
)

func generateSigningKey(alg signingKeyAlg) (crypto.Signer, error) {
	switch alg {
	case algEd25519:
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, fmt.Errorf("generate keypair: %w", err)
		}
		return priv, nil
	case algP256:
		priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, fmt.Errorf("generate keypair: %w", err)
		}
		return priv, nil
	default:
		return nil, fmt.Errorf("--key must be %s or %s, got %q", algEd25519, algP256, alg)
	}
}

// encodePrivateKey renders a private key as one line: base64 of its PKCS#8 DER.
// One line is what makes it pasteable into an env var, a secret manager, or a
// client's config block without a heredoc.
func encodePrivateKey(key crypto.Signer) (string, error) {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return "", fmt.Errorf("encode private key: %w", err)
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// parsePrivateKey reads the one-line form back. It accepts only the key
// algorithms the profile signs with, so an unusable key fails here rather than
// as an opaque signature refusal at an enforcing runner.
func parsePrivateKey(encoded string) (crypto.Signer, error) {
	der, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, fmt.Errorf("--ca-key is not valid base64: %w", err)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, fmt.Errorf("--ca-key is not a PKCS#8 private key: %w", err)
	}
	switch key := parsed.(type) {
	case ed25519.PrivateKey:
		return key, nil
	case *ecdsa.PrivateKey:
		if key.Curve != elliptic.P256() {
			return nil, fmt.Errorf("--ca-key is an ECDSA key on %s, only P-256 is accepted", key.Curve.Params().Name)
		}
		return key, nil
	default:
		return nil, fmt.Errorf("--ca-key algorithm %T is not accepted for dispatch signing", parsed)
	}
}

func encodeCertPEM(der []byte) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

// encodeCertChain renders leaf-first DER as the one-line EMISAR_SIGNING_CERT
// value: base64 of the PEM chain text. The bridge decodes it, splits the PEM
// blocks, and sends DER on the wire.
func encodeCertChain(chain [][]byte) string {
	var pemText strings.Builder
	for _, der := range chain {
		pemText.WriteString(encodeCertPEM(der))
	}
	return base64.StdEncoding.EncodeToString([]byte(pemText.String()))
}

// parseScope turns "group=edge,env=prod" into a Scope: the special key "group"
// sets Scope.Group (exact-match against the runner's group); every other k=v is
// a label the runner must also carry. An empty string is the explicit "any
// runner that trusts the CA" scope.
func parseScope(s string) (attest.Scope, error) {
	scope := attest.Scope{}
	s = strings.TrimSpace(s)
	if s == "" {
		return scope, nil
	}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, ok := strings.Cut(part, "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if !ok || k == "" || v == "" {
			return scope, fmt.Errorf("scope item %q must be key=value", part)
		}
		if k == "group" {
			scope.Group = v
			continue
		}
		if scope.Labels == nil {
			scope.Labels = map[string]string{}
		}
		scope.Labels[k] = v
	}
	return scope, nil
}

// The largest whole years that fit time.Duration's int64 nanoseconds.
const maxCertTTLYears = 292

// parseTTL accepts Go durations (24h, 90m) plus the long-form Nd / Ny that Go's
// time.ParseDuration can't express, for solo / break-glass certs. The long TTL
// trades away revocation granularity — documented in .agent/kb/specs/signed-dispatch.md.
func parseTTL(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if n, ok := strings.CutSuffix(s, "y"); ok {
		yrs, err := strconv.Atoi(n)
		// time.Duration is nanoseconds in an int64, so it tops out around 292
		// years. Past that the multiplication wrapped and minted a cert whose
		// not-after was in the PAST — an "unusable forever" cert that reads as a
		// long-lived one.
		if err != nil || yrs <= 0 || yrs > maxCertTTLYears {
			return 0, fmt.Errorf("invalid ttl %q (try e.g. 24h, 30d, 1y; max %dy)", s, maxCertTTLYears)
		}
		return time.Duration(yrs) * 365 * 24 * time.Hour, nil
	}
	if n, ok := strings.CutSuffix(s, "d"); ok {
		days, err := strconv.Atoi(n)
		if err != nil || days <= 0 {
			return 0, fmt.Errorf("invalid ttl %q (try e.g. 24h, 30d, 1y)", s)
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("invalid ttl %q: %w", s, err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("ttl must be positive, got %q", s)
	}
	return d, nil
}

// randomSerial mints a 128-bit positive serial. A certificate serial must be
// unpredictable rather than sequential so an issuer's output cannot be guessed
// or correlated.
func randomSerial() (*big.Int, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("generate serial: %w", err)
	}
	return serial.Add(serial, big.NewInt(1)), nil
}

// mintCA self-signs a CA certificate. pathLen 0 means it may issue leaves but
// no further CAs — this CLI's CA is a single-tier root, and a customer who
// needs an intermediate tier issues from their own PKI.
func mintCA(key crypto.Signer, name string, ttl time.Duration) ([]byte, error) {
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(ttl),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		return nil, fmt.Errorf("sign CA certificate: %w", err)
	}
	return der, nil
}

// mintLeaf issues a dispatch-signing certificate carrying the scope as its one
// emisar URI SAN. That SAN is what makes the certificate recognisable as ours;
// without it an enforcing runner refuses the dispatch as cert_profile.
// caKeyMaterial resolves the CA private key from a file or from argv.
//
// --ca-key takes the key MATERIAL, so the root of trust for signed dispatch
// lands in shell history and in the process table, where every other user on
// the host can read it while the command runs. --ca-key-file is the way to
// avoid that, and there was none. The argv form stays — scripts use it, and
// removing it now would break them — but the file form is what the help
// recommends.
//
// Exactly one, because silently preferring one over the other is how an
// operator ends up signing with a key they did not think they passed.
func caKeyMaterial(inline, file string) (string, error) {
	switch {
	case inline == "" && file == "":
		return "", usageError{errors.New("provide --ca-key-file (preferred) or --ca-key")}
	case inline != "" && file != "":
		return "", usageError{errors.New("--ca-key and --ca-key-file are alternatives; pass one")}
	case file != "":
		material, err := os.ReadFile(file)
		if err != nil {
			return "", fmt.Errorf("read CA key: %w", err)
		}
		return strings.TrimSpace(string(material)), nil
	default:
		return inline, nil
	}
}

func mintLeaf(caKey crypto.Signer, caCert *x509.Certificate, leafPub crypto.PublicKey, name string, scope attest.Scope, ttl time.Duration) ([]byte, error) {
	scopeURI, err := attest.EncodeScopeURI(scope)
	if err != nil {
		return nil, err
	}
	parsedURI, err := url.Parse(scopeURI)
	if err != nil {
		return nil, fmt.Errorf("scope URI: %w", err)
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(ttl),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  false,
		URIs:                  []*url.URL{parsedURI},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, caCert, leafPub, caKey)
	if err != nil {
		return nil, fmt.Errorf("sign certificate: %w", err)
	}
	return der, nil
}

// printTrustBlock prints the runner config an operator pastes on every host.
// The anchor is a PEM certificate — public, safe to commit, and shipped the
// same way as the rest of config.yaml.
func printTrustBlock(name, caPEM string) {
	fmt.Print("   signing:\n")
	fmt.Print("     enforce_signatures: true\n")
	fmt.Print("     trusted_cas:\n")
	fmt.Printf("       - name: %s\n", name)
	fmt.Print("         pem: |\n")
	for _, line := range strings.Split(strings.TrimRight(caPEM, "\n"), "\n") {
		fmt.Printf("           %s\n", line)
	}
	fmt.Println()
}

// signingNewCACmd mints a CA keypair and its self-signed certificate. The
// CERTIFICATE goes in every runner's signing.trusted_cas (safe to commit); the
// PRIVATE key is stored OFFLINE and used only by `emisar signing new-cert`.
func signingNewCACmd() *cobra.Command {
	var caName, ttlStr string
	var keyAlg string
	cmd := &cobra.Command{
		Use:   "new-ca",
		Short: "Mint just the offline CA keypair (the root of trust; rarely)",
		Long: `signing new-ca mints a certificate-authority keypair and its self-signed
certificate.

The CERTIFICATE goes in every runner's config under signing.trusted_cas (safe to
commit). The PRIVATE key stays OFFLINE — keep it on an operator's machine or a
vault, never on a runner and never on the control plane. You issue short-lived
operator certificates with it via
"emisar signing new-cert --ca-key <private-key> --ca-cert <certificate>".

To issue from your own PKI instead, see the certificate profile in
https://emisar.dev/docs/signed-dispatch.`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			ttl, err := parseTTL(ttlStr)
			if err != nil {
				return err
			}
			key, err := generateSigningKey(signingKeyAlg(keyAlg))
			if err != nil {
				return err
			}
			if caName == "" {
				caName = "emisar-dispatch-ca"
			}
			caDER, err := mintCA(key, caName, ttl)
			if err != nil {
				return err
			}
			caKeyEncoded, err := encodePrivateKey(key)
			if err != nil {
				return err
			}
			caPEM := encodeCertPEM(caDER)

			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"ca_name": caName, "ca_certificate": caPEM, "ca_private_key": caKeyEncoded,
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}
			fmt.Printf("Minted an offline signing CA (%s).\n\n", caName)
			fmt.Print("1. Runner config — add under signing on every runner (the CERTIFICATE is safe to commit):\n\n")
			printTrustBlock(caName, caPEM)
			fmt.Print("2. CA PRIVATE key — store this OFFLINE (never on a runner or the control plane):\n\n")
			fmt.Printf("   %s\n\n", caKeyEncoded)
			fmt.Print("Issue operator certificates with:\n")
			fmt.Print("   emisar signing new-cert --ca-key <the-private-key-above> --ca-cert <the-certificate-above> --scope group=<g> --ttl 24h\n")
			return nil
		},
	}
	cmd.Flags().StringVar(&caName, "ca-name", "", "CA common name (default: emisar-dispatch-ca)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "5y", "CA validity duration: 1y, 5y")
	cmd.Flags().StringVar(&keyAlg, "key", string(algEd25519), "key algorithm: ed25519 or p256")
	return cmd
}

// signingNewCertCmd issues a certificate for a leaf key. It mints the leaf
// keypair too, printing both MCP env vars.
func signingNewCertCmd() *cobra.Command {
	var caKey, caKeyFile, caCertPEM, keyName, scopeStr, ttlStr, keyAlg string
	cmd := &cobra.Command{
		Use:   "new-cert",
		Short: "Mint a short-lived operator certificate (routinely, as certs expire)",
		Long: `signing new-cert issues a short-lived (optionally scoped) certificate against
the offline CA, producing the two env vars the MCP bridge carries:
EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT.

The CA private key is read locally from --ca-key and used only to sign; it is
never transmitted. Prefer short --ttl values (24h): expiry is the only
revocation, so a long TTL keeps a leaked certificate usable longer.`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			material, err := caKeyMaterial(caKey, caKeyFile)
			if err != nil {
				return err
			}
			signer, err := parsePrivateKey(material)
			if err != nil {
				return err
			}
			caCert, err := parseCACertificate(caCertPEM)
			if err != nil {
				return err
			}
			scope, err := parseScope(scopeStr)
			if err != nil {
				return err
			}
			ttl, err := parseTTL(ttlStr)
			if err != nil {
				return err
			}
			leafKey, err := generateSigningKey(signingKeyAlg(keyAlg))
			if err != nil {
				return err
			}
			if keyName == "" {
				keyName = "emisar-operator"
			}
			leafDER, err := mintLeaf(signer, caCert, leafKey.Public(), keyName, scope, ttl)
			if err != nil {
				return err
			}
			leafKeyEncoded, err := encodePrivateKey(leafKey)
			if err != nil {
				return err
			}
			leaf, err := x509.ParseCertificate(leafDER)
			if err != nil {
				return fmt.Errorf("parse issued certificate: %w", err)
			}
			chain := encodeCertChain([][]byte{leafDER})

			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"key_name": keyName, "private_key": leafKeyEncoded, "certificate_chain": chain,
					"not_after": leaf.NotAfter.UTC().Format(time.RFC3339),
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}
			fmt.Printf("Issued a certificate (%s, valid until %s).\n\n",
				keyName, leaf.NotAfter.UTC().Format(time.RFC3339))
			fmt.Print("MCP client — set these env vars (keep the private key SECRET):\n\n")
			fmt.Printf("   EMISAR_SIGNING_KEY=%s\n", leafKeyEncoded)
			fmt.Printf("   EMISAR_SIGNING_CERT=%s\n", chain)
			return nil
		},
	}
	cmd.Flags().StringVar(&caKey, "ca-key", "", "CA PRIVATE key material from `signing new-ca` (prefer --ca-key-file)")
	cmd.Flags().StringVar(&caKeyFile, "ca-key-file", "", "file holding the CA private key from `signing new-ca`")
	cmd.Flags().StringVar(&caCertPEM, "ca-cert", "", "CA certificate PEM from `signing new-ca` [required]")
	cmd.Flags().StringVar(&keyName, "key-name", "", "leaf common name (default: emisar-operator)")
	cmd.Flags().StringVar(&scopeStr, "scope", "", "cert scope, e.g. group=edge,env=prod (empty = any runner)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "24h", "validity duration: 24h, 30d, 1y")
	cmd.Flags().StringVar(&keyAlg, "key", string(algEd25519), "key algorithm: ed25519 or p256")
	_ = cmd.MarkFlagRequired("ca-cert")
	return cmd
}

// parseCACertificate reads the issuing CA certificate. It is required on
// new-cert because an X.509 leaf must name its issuer exactly: the runner
// matches the chain by issuer name and key, not by a label an operator retyped.
func parseCACertificate(pemText string) (*x509.Certificate, error) {
	block, _ := pem.Decode([]byte(strings.TrimSpace(pemText)))
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("--ca-cert is not a PEM CERTIFICATE block")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("--ca-cert does not parse: %w", err)
	}
	if !cert.BasicConstraintsValid || !cert.IsCA {
		return nil, fmt.Errorf("--ca-cert is not a CA certificate")
	}
	return cert, nil
}

// signingCmd is the signed-dispatch command group (`emisar signing …`): the
// one-shot `init` on-ramp plus the granular `new-ca` / `new-cert` operations
// for CA rotation and routine cert renewal.
func signingCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "signing",
		Short: "Set up bridge-attested (signed) dispatch",
		Long: `Signed dispatch lets an enforcing runner require a CA-signed certificate on
every action, so a compromised control plane can relay but never mint a
dispatch. "signing init" is the one-shot on-ramp; "new-ca" and "new-cert" are
the granular operations for CA rotation and routine cert renewal.

Certificates are X.509, so your own PKI can issue them instead — the profile is
documented at https://emisar.dev/docs/signed-dispatch.`,
		Args: cobra.NoArgs,
		RunE: showHelp,
	}
	cmd.AddCommand(emitsJSON(signingInitCmd()))
	cmd.AddCommand(emitsJSON(signingNewCACmd()))
	cmd.AddCommand(emitsJSON(signingNewCertCmd()))
	return cmd
}

// signingInitCmd is the one-command on-ramp: mint a CA + a leaf + a certificate
// and print the runner block, the offline CA private key, and both MCP env vars.
func signingInitCmd() *cobra.Command {
	var caName, scopeStr, ttlStr, keyAlg string
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Set up signed dispatch in one shot (CA + cert + config)",
		Long: `signing init mints a CA, a leaf keypair, and a certificate in one step and
prints the full runner config block, the offline CA private key to store, and
the two MCP env vars. The simplest on-ramp to bridge-attested dispatch — after
this, issue fresh certificates as they expire with "emisar signing new-cert".`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			scope, err := parseScope(scopeStr)
			if err != nil {
				return err
			}
			ttl, err := parseTTL(ttlStr)
			if err != nil {
				return err
			}
			alg := signingKeyAlg(keyAlg)
			caKey, err := generateSigningKey(alg)
			if err != nil {
				return err
			}
			if caName == "" {
				caName = "emisar-dispatch-ca"
			}
			caDER, err := mintCA(caKey, caName, 5*365*24*time.Hour)
			if err != nil {
				return err
			}
			caCert, err := x509.ParseCertificate(caDER)
			if err != nil {
				return fmt.Errorf("parse CA certificate: %w", err)
			}
			leafKey, err := generateSigningKey(alg)
			if err != nil {
				return err
			}
			leafDER, err := mintLeaf(caKey, caCert, leafKey.Public(), "emisar-operator", scope, ttl)
			if err != nil {
				return err
			}
			leaf, err := x509.ParseCertificate(leafDER)
			if err != nil {
				return fmt.Errorf("parse issued certificate: %w", err)
			}
			caKeyEncoded, err := encodePrivateKey(caKey)
			if err != nil {
				return err
			}
			leafKeyEncoded, err := encodePrivateKey(leafKey)
			if err != nil {
				return err
			}
			caPEM := encodeCertPEM(caDER)
			chain := encodeCertChain([][]byte{leafDER})

			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"ca_name": caName, "ca_certificate": caPEM, "ca_private_key": caKeyEncoded,
					"private_key": leafKeyEncoded, "certificate_chain": chain,
					"not_after": leaf.NotAfter.UTC().Format(time.RFC3339),
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}

			fmt.Printf("Initialized signed dispatch (%s, valid until %s).\n\n",
				caName, leaf.NotAfter.UTC().Format(time.RFC3339))
			fmt.Print("1. Runner config — add under signing on every runner (PUBLIC, safe to commit):\n\n")
			printTrustBlock(caName, caPEM)
			fmt.Print("2. CA PRIVATE key — store OFFLINE; you re-issue certificates with it as they expire:\n\n")
			fmt.Printf("   %s\n\n", caKeyEncoded)
			fmt.Print("3. MCP client — set these env vars (keep the private key SECRET):\n\n")
			fmt.Printf("   EMISAR_SIGNING_KEY=%s\n", leafKeyEncoded)
			fmt.Printf("   EMISAR_SIGNING_CERT=%s\n\n", chain)
			fmt.Print("Restart the runner after applying this config so it opens durable replay state\n")
			fmt.Print("and advertises enforcement. Never put the CA or leaf private key on the\n")
			fmt.Print("control plane or in version control.\n")
			return nil
		},
	}
	cmd.Flags().StringVar(&caName, "ca-name", "", "CA common name (default: emisar-dispatch-ca)")
	cmd.Flags().StringVar(&scopeStr, "scope", "", "cert scope, e.g. group=edge,env=prod (empty = any runner)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "24h", "cert validity duration: 24h, 30d, 1y")
	cmd.Flags().StringVar(&keyAlg, "key", string(algEd25519), "key algorithm: ed25519 or p256")
	return cmd
}
