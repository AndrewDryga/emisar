package packs

import (
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// wg.showconf runs `wg showconf <iface>`, whose INI output includes the
// interface PrivateKey and each peer's PresharedKey — the secret halves of the
// tunnel. The action is risk:low (no approval gate) and its stdout streams to
// the LLM/audit. The always-on default rules catch the `PrivateKey =` line (via
// the generic secret-assignment rule) but do NOT match `PresharedKey =`, so the
// action's own redact rules must mask both at the source. This loads the REAL
// action from packs/ and proves that on representative `wg showconf` output no
// key material survives while the interface/peer topology stays intact.
func TestWireguardShowconf_RedactsKeyMaterial(t *testing.T) {
	reg := loadRealLibrary(t)
	act, ok := reg.Action("wg.showconf")
	if !ok {
		t.Fatal("wg.showconf not found in the real library (id drifted?)")
	}

	rules := make([]redact.Rule, 0, len(act.Output.Redact))
	for _, rr := range act.Output.Redact {
		r, err := redact.CompileRule(rr)
		if err != nil {
			t.Fatalf("compiling redact rule %q: %v", rr.Name, err)
		}
		rules = append(rules, r)
	}
	if len(rules) == 0 {
		t.Fatal("wg.showconf declares NO redact rule — private/preshared keys leak")
	}

	// Representative `wg showconf wg0` output: 44-char base64 keys, one peer
	// with a preshared key. The private and preshared keys are the secrets.
	const (
		privKey = "aB3dEfGhIjKlMnOpQrStUvWxYz0123456789ABCDeFg="
		pskKey  = "ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFfE="
		pubKey  = "PubLicKey0000000000000000000000000000000000="
	)
	stdout := strings.Join([]string{
		`[Interface]`,
		`ListenPort = 51820`,
		`FwMark = 0x5678`,
		`PrivateKey = ` + privKey,
		``,
		`[Peer]`,
		`PublicKey = ` + pubKey,
		`PresharedKey = ` + pskKey,
		`AllowedIPs = 10.0.0.2/32`,
		`Endpoint = 192.0.2.10:51820`,
		`PersistentKeepalive = 25`,
	}, "\n")

	out, _ := redact.New(rules).Apply(stdout)

	if strings.Contains(out, privKey) {
		t.Fatalf("interface PrivateKey leaked through redaction:\n%s", out)
	}
	if strings.Contains(out, pskKey) {
		t.Fatalf("peer PresharedKey leaked through redaction:\n%s", out)
	}
	if !strings.Contains(out, "PrivateKey = [REDACTED]") {
		t.Fatalf("expected PrivateKey masked with [REDACTED], got:\n%s", out)
	}
	if !strings.Contains(out, "PresharedKey = [REDACTED]") {
		t.Fatalf("expected PresharedKey masked with [REDACTED], got:\n%s", out)
	}
	// The topology the action exists to surface must survive — public key,
	// allowed-ips, endpoint, ports.
	for _, keep := range []string{
		"PublicKey = " + pubKey,
		"AllowedIPs = 10.0.0.2/32",
		"Endpoint = 192.0.2.10:51820",
		"ListenPort = 51820",
	} {
		if !strings.Contains(out, keep) {
			t.Fatalf("redaction over-matched and scrubbed %q:\n%s", keep, out)
		}
	}
}
