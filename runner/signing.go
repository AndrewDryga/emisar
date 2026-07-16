package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/attest"
)

// The signing CLI is OFFLINE by design: every key it mints is printed locally
// and sent nowhere. The CA private key in particular must stay offline/
// customer-held — the whole threat model is that a compromised control plane can
// RELAY a certified dispatch but never MINT one, so nothing here writes a CA key
// anywhere the portal can reach.

// generateEd25519 mints a keypair and returns hex encodings: the 32-byte seed is
// the PRIVATE key, the 32-byte public key is safe to publish. id defaults to a
// short prefixed random label when empty.
func generateEd25519(id, prefix string) (outID, pubHex, seedHex string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", "", fmt.Errorf("generate keypair: %w", err)
	}
	seedHex = hex.EncodeToString(priv.Seed())
	pubHex = hex.EncodeToString(pub)
	if id == "" {
		id = prefix + seedHex[:8]
	}
	return id, pubHex, seedHex, nil
}

// parseCASeed decodes the offline CA private key (a hex Ed25519 seed) supplied
// to `signing new-cert`. It never leaves the operator's machine.
func parseCASeed(seedHex string) (ed25519.PrivateKey, error) {
	seed, err := hex.DecodeString(strings.TrimSpace(seedHex))
	if err != nil {
		return nil, fmt.Errorf("--ca-key is not valid hex: %w", err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("--ca-key is %d bytes, want %d (an Ed25519 seed)", len(seed), ed25519.SeedSize)
	}
	return ed25519.NewKeyFromSeed(seed), nil
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

// parseTTL accepts Go durations (24h, 90m) plus the long-form Nd / Ny that Go's
// time.ParseDuration can't express, for solo / break-glass certs. The long TTL
// trades away revocation granularity — documented in docs/signed-dispatch.md.
func parseTTL(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if n, ok := strings.CutSuffix(s, "y"); ok {
		yrs, err := strconv.Atoi(n)
		if err != nil || yrs <= 0 {
			return 0, fmt.Errorf("invalid ttl %q (try e.g. 24h, 30d, 1y)", s)
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

// mintCert builds and CA-signs a cert vouching for leafPubHex over scope for ttl
// starting now (UTC). The serial is a ULID for audit + future revocation.
func mintCert(caPriv ed25519.PrivateKey, caID, keyID, leafPubHex string, scope attest.Scope, ttl time.Duration) (attest.Cert, error) {
	now := time.Now().UTC()
	cert := attest.Cert{
		CAID:       caID,
		KeyID:      keyID,
		PublicKey:  leafPubHex,
		ValidFrom:  now.Format(time.RFC3339),
		ValidUntil: now.Add(ttl).Format(time.RFC3339),
		Scope:      scope,
		Serial:     ulid.Make().String(),
	}
	sig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		return attest.Cert{}, fmt.Errorf("sign cert: %w", err)
	}
	cert.Sig = sig
	return cert, nil
}

// signingNewCACmd mints a CA keypair. The PUBLIC key goes in every runner's
// signing.trusted_cas (safe to commit); the PRIVATE key is stored OFFLINE and
// used only by `emisar signing new-cert` to mint operator certs.
func signingNewCACmd() *cobra.Command {
	var caID string
	cmd := &cobra.Command{
		Use:   "new-ca",
		Short: "Mint just the offline CA keypair (the root of trust; rarely)",
		Long: `signing new-ca mints an Ed25519 certificate-authority keypair.

The PUBLIC key goes in every runner's config under signing.trusted_cas (safe to
commit). The PRIVATE key stays OFFLINE — keep it on an operator's machine or a
vault, never on a runner and never on the control plane. You sign short-lived
operator certs with it via "emisar signing new-cert --ca-key <private-key>".`,
		RunE: func(_ *cobra.Command, _ []string) error {
			id, pubHex, seedHex, err := generateEd25519(caID, "ca-")
			if err != nil {
				return err
			}
			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"ca_id": id, "public_key": pubHex, "private_key": seedHex,
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}
			fmt.Printf("Minted an offline signing CA (ca_id: %s).\n\n", id)
			fmt.Print("1. Runner config — add under signing on every runner (the PUBLIC key is safe to commit):\n\n")
			fmt.Print("   signing:\n")
			fmt.Print("     enforce_signatures: true\n")
			fmt.Print("     trusted_cas:\n")
			fmt.Printf("       - ca_id: %s\n", id)
			fmt.Printf("         public_key: %s\n\n", pubHex)
			fmt.Print("2. CA PRIVATE key — store this OFFLINE (never on a runner or the control plane):\n\n")
			fmt.Printf("   %s\n\n", seedHex)
			fmt.Print("Mint operator certs with:\n")
			fmt.Printf("   emisar signing new-cert --ca-id %s --ca-key <the-private-key-above> --key-id <operator> --scope group=<g> --ttl 24h\n", id)
			return nil
		},
	}
	cmd.Flags().StringVar(&caID, "ca-id", "", "CA id to label the keypair (default: ca-<random>)")
	return cmd
}

// signingNewCertCmd signs a cert for a leaf key. If --pubkey is omitted it also
// mints the leaf keypair and prints the seed for EMISAR_SIGNING_KEY. The cert
// JSON is the EMISAR_SIGNING_CERT value the MCP client carries.
func signingNewCertCmd() *cobra.Command {
	var caID, caKey, keyID, scopeStr, ttlStr, pubkey string
	cmd := &cobra.Command{
		Use:   "new-cert",
		Short: "Mint a short-lived operator certificate (routinely, as certs expire)",
		Long: `signing new-cert signs an Ed25519 leaf key with the offline CA private key,
producing a short-lived (optionally scoped) certificate the MCP client carries
as EMISAR_SIGNING_CERT. If --pubkey is omitted, a leaf keypair is also minted
and its private seed printed for EMISAR_SIGNING_KEY.

The CA private key is read locally from --ca-key and used only to sign; it is
never transmitted. Prefer short --ttl values (24h) — a long TTL (e.g. 1y) is for
solo / break-glass and trades away revocation granularity (there is no CRL yet;
rotate the CA to revoke).`,
		RunE: func(_ *cobra.Command, _ []string) error {
			if caID == "" {
				return fmt.Errorf("--ca-id is required (it must match the runner's trusted_cas ca_id)")
			}
			caPriv, err := parseCASeed(caKey)
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

			var leafSeed string
			leafPub := strings.TrimSpace(pubkey)
			if leafPub == "" {
				keyID, leafPub, leafSeed, err = generateEd25519(keyID, "op-")
				if err != nil {
					return err
				}
			} else {
				if _, err := hex.DecodeString(leafPub); err != nil {
					return fmt.Errorf("--pubkey is not valid hex: %w", err)
				}
				if keyID == "" {
					keyID = "op-" + leafPub[:8]
				}
			}

			cert, err := mintCert(caPriv, caID, keyID, leafPub, scope, ttl)
			if err != nil {
				return err
			}
			certJSON, err := json.Marshal(cert)
			if err != nil {
				return fmt.Errorf("marshal cert: %w", err)
			}

			if flagJSONOut {
				out := map[string]string{"cert": string(certJSON)}
				if leafSeed != "" {
					out["private_key"] = leafSeed
				}
				blob, _ := json.MarshalIndent(out, "", "  ")
				fmt.Println(string(blob))
				return nil
			}

			fmt.Printf("Signed a certificate (key_id: %s, serial: %s, valid until %s).\n\n", cert.KeyID, cert.Serial, cert.ValidUntil)
			fmt.Print("MCP client — set these env vars (keep the private key SECRET):\n\n")
			if leafSeed != "" {
				fmt.Printf("   EMISAR_SIGNING_KEY=%s\n", leafSeed)
			}
			fmt.Printf("   EMISAR_SIGNING_CERT=%s\n\n", string(certJSON))
			if leafSeed == "" {
				fmt.Print("(You supplied --pubkey, so set EMISAR_SIGNING_KEY to that key's private seed.)\n")
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&caID, "ca-id", "", "CA id (must match the runner's trusted_cas ca_id) [required]")
	cmd.Flags().StringVar(&caKey, "ca-key", "", "CA PRIVATE key (hex seed) from `signing new-ca` [required]")
	cmd.Flags().StringVar(&keyID, "key-id", "", "leaf key id (default: op-<random>)")
	cmd.Flags().StringVar(&scopeStr, "scope", "", "cert scope, e.g. group=edge,env=prod (empty = any runner)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "24h", "validity duration: 24h, 30d, 1y")
	cmd.Flags().StringVar(&pubkey, "pubkey", "", "leaf PUBLIC key (hex); if omitted, a leaf keypair is minted")
	_ = cmd.MarkFlagRequired("ca-key")
	return cmd
}

// signingCmd is the signed-dispatch command group (`emisar signing …`): the
// one-shot `init` on-ramp plus the granular `new-ca` / `new-cert` operations
// for CA rotation and routine cert renewal.
func signingCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "signing",
		Short: "Set up client-attested (signed) dispatch",
		Long: `Signed dispatch lets an enforcing runner require a CA-signed certificate on
every action, so a compromised control plane can relay but never mint a
dispatch. "signing init" is the one-shot on-ramp; "new-ca" and "new-cert" are
the granular operations for CA rotation and routine cert renewal.`,
	}
	cmd.AddCommand(signingInitCmd())
	cmd.AddCommand(signingNewCACmd())
	cmd.AddCommand(signingNewCertCmd())
	return cmd
}

// signingInitCmd is the one-command on-ramp: mint a CA + a leaf + a cert and
// print the runner block, the offline CA private key, and both MCP env vars.
func signingInitCmd() *cobra.Command {
	var caID, scopeStr, ttlStr string
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Set up signed dispatch in one shot (CA + cert + config)",
		Long: `signing init mints a CA, a leaf keypair, and a certificate in one step and
prints the full runner config block, the offline CA private key to store, and
the two MCP env vars. The simplest on-ramp to client-attested dispatch — after
this, mint fresh certs as they expire with "emisar signing new-cert".`,
		RunE: func(_ *cobra.Command, _ []string) error {
			scope, err := parseScope(scopeStr)
			if err != nil {
				return err
			}
			ttl, err := parseTTL(ttlStr)
			if err != nil {
				return err
			}
			caID, caPubHex, caSeedHex, err := generateEd25519(caID, "ca-")
			if err != nil {
				return err
			}
			caPriv, err := parseCASeed(caSeedHex)
			if err != nil {
				return err
			}
			keyID, leafPub, leafSeed, err := generateEd25519("", "op-")
			if err != nil {
				return err
			}
			cert, err := mintCert(caPriv, caID, keyID, leafPub, scope, ttl)
			if err != nil {
				return err
			}
			certJSON, err := json.Marshal(cert)
			if err != nil {
				return fmt.Errorf("marshal cert: %w", err)
			}

			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"ca_id": caID, "ca_public_key": caPubHex, "ca_private_key": caSeedHex,
					"key_id": keyID, "private_key": leafSeed, "cert": string(certJSON),
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}

			fmt.Printf("Initialized signed dispatch (ca_id: %s, key_id: %s, valid until %s).\n\n", caID, keyID, cert.ValidUntil)
			fmt.Print("1. Runner config — add under signing on every runner (PUBLIC, safe to commit):\n\n")
			fmt.Print("   signing:\n")
			fmt.Print("     enforce_signatures: true\n")
			fmt.Print("     trusted_cas:\n")
			fmt.Printf("       - ca_id: %s\n", caID)
			fmt.Printf("         public_key: %s\n\n", caPubHex)
			fmt.Print("2. CA PRIVATE key — store OFFLINE; you re-sign certs with it as they expire:\n\n")
			fmt.Printf("   %s\n\n", caSeedHex)
			fmt.Print("3. MCP client — set these env vars (keep the private key SECRET):\n\n")
			fmt.Printf("   EMISAR_SIGNING_KEY=%s\n", leafSeed)
			fmt.Printf("   EMISAR_SIGNING_CERT=%s\n\n", string(certJSON))
			fmt.Print("Restart the runner after applying this config so it opens durable replay state\n")
			fmt.Print("and advertises enforcement. Never put the CA or leaf private key on the\n")
			fmt.Print("control plane or in version control.\n")
			return nil
		},
	}
	cmd.Flags().StringVar(&caID, "ca-id", "", "CA id to label the keypair (default: ca-<random>)")
	cmd.Flags().StringVar(&scopeStr, "scope", "", "cert scope, e.g. group=edge,env=prod (empty = any runner)")
	cmd.Flags().StringVar(&ttlStr, "ttl", "24h", "cert validity duration: 24h, 30d, 1y")
	return cmd
}
