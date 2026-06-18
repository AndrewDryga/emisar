package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"
)

// generateSigningKey mints an Ed25519 keypair for client-attested dispatch and
// returns hex encodings: the 32-byte seed is the PRIVATE key (the MCP client's
// EMISAR_SIGNING_KEY), the 32-byte public key goes in the runner's trusted_keys.
// keyID defaults to a short random label when empty.
func generateSigningKey(keyID string) (id, pubHex, seedHex string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", "", fmt.Errorf("generate keypair: %w", err)
	}
	seed := priv.Seed()
	seedHex = hex.EncodeToString(seed)
	pubHex = hex.EncodeToString(pub)
	id = keyID
	if id == "" {
		id = "mcp-" + seedHex[:8]
	}
	return id, pubHex, seedHex, nil
}

// keygenCmd generates a keypair for signed (client-attested) dispatch. It is
// OFFLINE by design — the private key is printed locally and sent nowhere, which
// is the whole point of the scheme: the control plane never holds it, so it can
// relay a signed dispatch but never originate one.
func keygenCmd() *cobra.Command {
	var keyID string
	cmd := &cobra.Command{
		Use:   "keygen",
		Short: "Generate an Ed25519 keypair for signed (client-attested) dispatch",
		Long: `keygen mints an Ed25519 signing keypair for client-attested dispatch.

The PUBLIC key goes in this runner's config under signing.trusted_keys; the
PRIVATE key goes to the MCP client as EMISAR_SIGNING_KEY. With enforcement on,
the runner runs only dispatches a real user signed in their MCP client — the
control plane can relay them but never originate one.

The keypair is generated locally and sent nowhere. Keep the private key secret
and off the control plane.`,
		RunE: func(_ *cobra.Command, _ []string) error {
			id, pubHex, seedHex, err := generateSigningKey(keyID)
			if err != nil {
				return err
			}

			if flagJSONOut {
				out, _ := json.MarshalIndent(map[string]string{
					"key_id":      id,
					"public_key":  pubHex,
					"private_key": seedHex,
				}, "", "  ")
				fmt.Println(string(out))
				return nil
			}

			fmt.Printf("Generated an Ed25519 signing keypair (key_id: %s).\n\n", id)
			fmt.Print("1. Runner config — add under signing (the PUBLIC key is safe to commit):\n\n")
			fmt.Print("   signing:\n")
			fmt.Print("     enforce_signatures: true\n")
			fmt.Print("     trusted_keys:\n")
			fmt.Printf("       - key_id: %s\n", id)
			fmt.Printf("         public_key: %s\n\n", pubHex)
			fmt.Print("2. MCP client — set these env vars (the PRIVATE key, keep it SECRET):\n\n")
			fmt.Printf("   EMISAR_SIGNING_KEY=%s\n", seedHex)
			fmt.Printf("   EMISAR_SIGNING_KEY_ID=%s\n\n", id)
			fmt.Print("Reload the runner (SIGHUP or restart) to advertise enforcement.\n")
			fmt.Print("Never put the private key on the control plane or in version control.\n")
			return nil
		},
	}
	cmd.Flags().StringVar(&keyID, "key-id", "", "key id to label the keypair (default: mcp-<random>)")
	return cmd
}
