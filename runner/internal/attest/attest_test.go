package attest

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

const (
	vectorSeedHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	vectorPubHex  = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
)

func vectorClaims() []struct {
	name  string
	claim Claim
	bytes string
	sig   string
} {
	return []struct {
		name  string
		claim Claim
		bytes string
		sig   string
	}{
		{
			name: "empty args",
			claim: Claim{
				PortalOrigin: "https://emisar.dev", ActionID: "linux.uptime",
				PackRef: "linux@1.0.0/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				ArgsRaw: json.RawMessage(`{}`), RunnerRefs: []string{"db-a~11111111111111111111111111111111"},
				Reason: "Check load.", OperationID: "op_01", Nonce: "00000000000000000000000000000001",
				IssuedAt: "2026-06-17T12:00:00Z",
			},
			bytes: `{"version":"emisar-attestation-v5","tool":"run_action","portal_origin":"https://emisar.dev","action_id":"linux.uptime","pack_ref":"linux@1.0.0/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","args_sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a","runner_refs_sha256":"589c61cbb2a6783bdd43f634b32c84a59040eed70a62e4b3cde9034511500c2d","reason":"Check load.","evidence_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","expected_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","operation_id":"op_01","nonce":"00000000000000000000000000000001","issued_at":"2026-06-17T12:00:00Z"}`,
			sig:   `1710cd8576e6ac256043e132e3e36989a94dbcfc3a0581c8aeb349e2108b89670faf288060758d129ea276cd1a0664fa6eddae0402565bf0dd079fc40fc8e907`,
		},
		{
			name: "exact large number and sorted runner refs",
			claim: Claim{
				PortalOrigin: "https://ops.example:8443", ActionID: "cockroach.pause_job",
				PackRef:     "cockroach@1.4.0/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				ArgsRaw:     json.RawMessage(`{"job_id":891234567890123456,"force":true}`),
				RunnerRefs:  []string{"db-b~33333333333333333333333333333333", "db-a~22222222222222222222222222222222"},
				Reason:      "Pause the selected job before maintenance.",
				Evidence:    "p99 write latency 40s since 12:10Z, job 891234567890123456 holds the lock",
				Expected:    "writes resume within 60s of the pause",
				OperationID: "op_02",
				Nonce:       "00000000000000000000000000000002", IssuedAt: "2026-06-17T12:05:00Z",
			},
			bytes: `{"version":"emisar-attestation-v5","tool":"run_action","portal_origin":"https://ops.example:8443","action_id":"cockroach.pause_job","pack_ref":"cockroach@1.4.0/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","args_sha256":"bfb315278c463b5e42d6ed32b071bf0389d887e2bd2877d08e57a4a36b02403f","runner_refs_sha256":"41bcc8c1820d2787411727666d93e585d4d32c798c6f25e2335130154cc7f079","reason":"Pause the selected job before maintenance.","evidence_sha256":"84f42024269cc69ef725a2841c5596edef7ad940d445f68c2e6af576b8877f43","expected_sha256":"1575b4783811db3956097c98d85ed8c5ea5fe283660e86eae46b322c02a34b54","operation_id":"op_02","nonce":"00000000000000000000000000000002","issued_at":"2026-06-17T12:05:00Z"}`,
			sig:   `1808fd25ea462ed1e0527497baf7c8e8b1f540c2205494c9bdc8522b390b3909b92d75b84c38ed0cd04913795ef5dd78e84f8fc9037b3d50be302a6ef5cd830d`,
		},
	}
}

func vectorKey(t *testing.T) (ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	seed, err := hex.DecodeString(vectorSeedHex)
	if err != nil {
		t.Fatalf("decode seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(pub); got != vectorPubHex {
		t.Fatalf("public key drifted: got %s want %s", got, vectorPubHex)
	}
	return priv, pub
}

func TestSigningBytesVectors(t *testing.T) {
	for _, vector := range vectorClaims() {
		t.Run(vector.name, func(t *testing.T) {
			got, err := SigningBytes(vector.claim)
			if err != nil {
				t.Fatalf("SigningBytes: %v", err)
			}
			if string(got) != vector.bytes {
				t.Fatalf("canonical bytes drifted:\n got %q\nwant %q", got, vector.bytes)
			}
		})
	}
}

func TestSignVectors(t *testing.T) {
	priv, pub := vectorKey(t)
	for _, vector := range vectorClaims() {
		t.Run(vector.name, func(t *testing.T) {
			got, err := Sign(priv, vector.claim)
			if err != nil {
				t.Fatalf("Sign: %v", err)
			}
			if got != vector.sig {
				t.Fatalf("signature drifted:\n got %s\nwant %s", got, vector.sig)
			}
			ok, err := Verify(pub, vector.claim, vector.sig)
			if err != nil || !ok {
				t.Fatalf("Verify = %v, %v; want true", ok, err)
			}
		})
	}
}

func TestSigningBytesBindsEveryIntentField(t *testing.T) {
	priv, pub := vectorKey(t)
	base := vectorClaims()[1].claim
	sig, err := Sign(priv, base)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	tampered := map[string]Claim{}
	add := func(name string, mutate func(*Claim)) {
		claim := base
		claim.ArgsRaw = append(json.RawMessage(nil), base.ArgsRaw...)
		claim.RunnerRefs = append([]string(nil), base.RunnerRefs...)
		mutate(&claim)
		tampered[name] = claim
	}
	add("portal origin", func(c *Claim) { c.PortalOrigin = "https://evil.example" })
	add("action", func(c *Claim) { c.ActionID = "cockroach.resume_job" })
	add("pack", func(c *Claim) { c.PackRef = strings.Replace(c.PackRef, "bbbb", "cccc", 1) })
	add("args", func(c *Claim) { c.ArgsRaw = json.RawMessage(`{"job_id":891234567890123457,"force":true}`) })
	add("runner refs", func(c *Claim) { c.RunnerRefs[0] = "db-c~44444444444444444444444444444444" })
	add("reason", func(c *Claim) { c.Reason = "Different reason." })
	add("operation", func(c *Claim) { c.OperationID = "op_other" })
	add("nonce", func(c *Claim) { c.Nonce = "ffffffffffffffffffffffffffffffff" })
	add("issued at", func(c *Claim) { c.IssuedAt = "2026-06-17T12:06:00Z" })

	for name, claim := range tampered {
		t.Run(name, func(t *testing.T) {
			ok, err := Verify(pub, claim, sig)
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			if ok {
				t.Fatal("tampered claim verified")
			}
		})
	}
}

func TestSigningBytesHardcodesRunActionDomain(t *testing.T) {
	got, err := SigningBytes(vectorClaims()[0].claim)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if !bytes.Contains(got, []byte(`"tool":"run_action"`)) {
		t.Fatalf("signed body does not bind run_action: %s", got)
	}
}

func TestArgsSHA256UsesExactObjectBytes(t *testing.T) {
	spellings := []json.RawMessage{
		json.RawMessage(`{"n":1000}`),
		json.RawMessage(`{"n":1e3}`),
		json.RawMessage(`{ "n" : 1000 }`),
	}
	digests := map[string]bool{}
	for _, raw := range spellings {
		digest, err := ArgsSHA256(raw)
		if err != nil {
			t.Fatalf("ArgsSHA256(%s): %v", raw, err)
		}
		digests[digest] = true
	}
	if len(digests) != len(spellings) {
		t.Fatal("distinct exact argument bytes produced the same digest")
	}

	empty, err := ArgsSHA256(nil)
	if err != nil {
		t.Fatalf("ArgsSHA256(nil): %v", err)
	}
	explicit, err := ArgsSHA256(json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("ArgsSHA256({}): %v", err)
	}
	if empty != explicit {
		t.Fatal("omitted no-argument object did not normalize to {}")
	}
}

func TestArgsSHA256RejectsInvalidOrNonObjectJSON(t *testing.T) {
	for _, raw := range []json.RawMessage{
		json.RawMessage(`null`), json.RawMessage(`[]`), json.RawMessage(`{"x":`), json.RawMessage(`1`),
	} {
		if _, err := ArgsSHA256(raw); err == nil {
			t.Fatalf("ArgsSHA256(%q) accepted invalid/non-object input", raw)
		}
	}
}

func TestCanonicalRunnerRefs(t *testing.T) {
	got, err := CanonicalRunnerRefs([]string{"z~22222222222222222222222222222222", "a~11111111111111111111111111111111"})
	if err != nil {
		t.Fatalf("CanonicalRunnerRefs: %v", err)
	}
	if strings.Join(got, ",") != "a~11111111111111111111111111111111,z~22222222222222222222222222222222" {
		t.Fatalf("sorted refs = %v", got)
	}
	tooMany := make([]string, MaxRunnerRefs+1)
	for i := range tooMany {
		tooMany[i] = string(rune('a' + i))
	}
	for _, refs := range [][]string{nil, {""}, {"same", "same"}, {strings.Repeat("x", MaxRunnerRefBytes+1)}, tooMany} {
		if _, err := CanonicalRunnerRefs(refs); err == nil {
			t.Fatalf("CanonicalRunnerRefs(%v) unexpectedly succeeded", refs)
		}
	}
}

func TestVerifyRejectsMalformedSignature(t *testing.T) {
	_, pub := vectorKey(t)
	ok, err := Verify(pub, vectorClaims()[0].claim, "not-hex")
	if err == nil || ok {
		t.Fatalf("Verify = %v, %v; want false, error", ok, err)
	}
}

const (
	vectorCASeedHex   = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	vectorCAPubHex    = "e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0"
	certBytes         = `{"version":"emisar-cert-v2","ca_id":"ca-acme","key_id":"op-alice","public_key":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","valid_from":"2026-06-25T00:00:00Z","valid_until":"2026-06-26T00:00:00Z","scope_sha256":"75d22a7b0f024c454095764648cb9e08de2df93cfed413b76fa0aa74d93fddd4","serial":"01J0CERT0000000000000000C"}`
	certSig           = "604cb20b49086c0018f70137a2a623ae9ea6aec82d3fd877b4719cb2e5e61ac16da7fb243902a22a6bb84d4bb3e16a1b861222ec749fee87f23281d418f2ba0a"
	envelopeBase64URL = "eyJ2ZXJzaW9uIjoiZW1pc2FyLWF0dGVzdGF0aW9uLXY1IiwidG9vbCI6InJ1bl9hY3Rpb24iLCJwb3J0YWxfb3JpZ2luIjoiaHR0cHM6Ly9vcHMuZXhhbXBsZTo4NDQzIiwiYWN0aW9uX2lkIjoiY29ja3JvYWNoLnBhdXNlX2pvYiIsInBhY2tfcmVmIjoiY29ja3JvYWNoQDEuNC4wL3NoYTI1NjpiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwiYXJnc19zaGEyNTYiOiJiZmIzMTUyNzhjNDYzYjVlNDJkNmVkMzJiMDcxYmYwMzg5ZDg4N2UyYmQyODc3ZDA4ZTU3YTRhMzZiMDI0MDNmIiwicnVubmVyX3JlZnMiOlsiZGItYX4yMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMiIsImRiLWJ-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMiXSwicmVhc29uIjoiUGF1c2UgdGhlIHNlbGVjdGVkIGpvYiBiZWZvcmUgbWFpbnRlbmFuY2UuIiwiZXZpZGVuY2Vfc2hhMjU2IjoiODRmNDIwMjQyNjljYzY5ZWY3MjVhMjg0MWM1NTk2ZWRlZjdhZDk0MGQ0NDVmNjhjMmU2YWY1NzZiODg3N2Y0MyIsImV4cGVjdGVkX3NoYTI1NiI6IjE1NzViNDc4MzgxMWRiMzk1NjA5N2M5OGQ4NWVkOGM1ZWE1ZmUyODM2NjBlODZlYWU0NmIzMjJjMDJhMzRiNTQiLCJvcGVyYXRpb25faWQiOiJvcF8wMiIsInNpZyI6IjE4MDhmZDI1ZWE0NjJlZDFlMDUyNzQ5N2JhZjdjOGU4YjFmNTQwYzIyMDU0OTRjOWJkYzg1MjJiMzkwYjM5MDliOTJkNzViODRjMzhlZDBjZDA0OTEzNzk1ZWY1ZGQ3OGU4NGY4ZmM5MDM3YjNkNTBiZTMwMmE2ZWY1Y2Q4MzBkIiwibm9uY2UiOiIwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMiIsImlzc3VlZF9hdCI6IjIwMjYtMDYtMTdUMTI6MDU6MDBaIiwiY2VydCI6eyJjYV9pZCI6ImNhLWFjbWUiLCJrZXlfaWQiOiJvcC1hbGljZSIsInB1YmxpY19rZXkiOiI3OWI1NTYyZThmZTY1NGY5NDA3OGIxMTJlOGE5OGJhNzkwMWY4NTNhZTY5NWJlZDdlMGUzOTEwYmFkMDQ5NjY0IiwidmFsaWRfZnJvbSI6IjIwMjYtMDYtMjVUMDA6MDA6MDBaIiwidmFsaWRfdW50aWwiOiIyMDI2LTA2LTI2VDAwOjAwOjAwWiIsInNjb3BlIjp7Imdyb3VwIjoiZWRnZSIsImxhYmVscyI6eyJlbnYiOiJwcm9kIiwicmVnaW9uIjoidXMifX0sInNlcmlhbCI6IjAxSjBDRVJUMDAwMDAwMDAwMDAwMDAwMEMiLCJzaWciOiI2MDRjYjIwYjQ5MDg2YzAwMThmNzAxMzdhMmE2MjNhZTllYTZhZWM4MmQzZmQ4NzdiNDcxOWNiMmU1ZTYxYWMxNmRhN2ZiMjQzOTAyYTIyYTZiYjg0ZDRiYjNlMTZhMWI4NjEyMjJlYzc0OWZlZTg3ZjIzMjgxZDQxOGYyYmEwYSJ9fQ"
)

func vectorCAKey(t *testing.T) (ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	seed, err := hex.DecodeString(vectorCASeedHex)
	if err != nil {
		t.Fatalf("decode CA seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(pub); got != vectorCAPubHex {
		t.Fatalf("CA public key drifted: got %s want %s", got, vectorCAPubHex)
	}
	return priv, pub
}

func vectorCert() Cert {
	return Cert{
		CAID: "ca-acme", KeyID: "op-alice", PublicKey: vectorPubHex,
		ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z",
		Scope:  Scope{Group: "edge", Labels: map[string]string{"region": "us", "env": "prod"}},
		Serial: "01J0CERT0000000000000000C", Sig: certSig,
	}
}

func vectorEnvelope(t *testing.T) Envelope {
	t.Helper()
	vector := vectorClaims()[1]
	argsDigest, err := ArgsSHA256(vector.claim.ArgsRaw)
	if err != nil {
		t.Fatalf("ArgsSHA256: %v", err)
	}
	cert := vectorCert()
	runnerRefs, err := CanonicalRunnerRefs(vector.claim.RunnerRefs)
	if err != nil {
		t.Fatalf("CanonicalRunnerRefs: %v", err)
	}
	return Envelope{
		Version: Version, Tool: Tool, PortalOrigin: vector.claim.PortalOrigin,
		ActionID: vector.claim.ActionID, PackRef: vector.claim.PackRef,
		ArgsSHA256: argsDigest, RunnerRefs: runnerRefs,
		Reason:         vector.claim.Reason,
		EvidenceSHA256: TextSHA256(vector.claim.Evidence),
		ExpectedSHA256: TextSHA256(vector.claim.Expected),
		OperationID:    vector.claim.OperationID,
		Signature:      vector.sig, Nonce: vector.claim.Nonce, IssuedAt: vector.claim.IssuedAt,
		Cert: &cert,
	}
}

func TestEnvelopeWireVector(t *testing.T) {
	raw, err := json.Marshal(vectorEnvelope(t))
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if got := base64.RawURLEncoding.EncodeToString(raw); got != envelopeBase64URL {
		t.Fatalf("envelope wire vector drifted:\n got %s\nwant %s", got, envelopeBase64URL)
	}

	decodedRaw, err := base64.RawURLEncoding.DecodeString(envelopeBase64URL)
	if err != nil {
		t.Fatalf("decode envelope vector: %v", err)
	}
	var decoded Envelope
	if err := json.Unmarshal(decodedRaw, &decoded); err != nil {
		t.Fatalf("unmarshal envelope vector: %v", err)
	}
	if decoded.Cert == nil || decoded.Cert.Sig != certSig || len(decoded.RunnerRefs) != 2 {
		t.Fatalf("decoded envelope lost signed fields: %+v", decoded)
	}
	// The narrative digests are the v5 addition, and an EMPTY one is not the
	// same as the digest of an empty string: the portal requires 64 lower-hex,
	// so a blank here would be an envelope it refuses.
	for name, digest := range map[string]string{
		"evidence_sha256": decoded.EvidenceSHA256,
		"expected_sha256": decoded.ExpectedSHA256,
	} {
		if len(digest) != 64 {
			t.Fatalf("%s is %q, want a 64-character digest", name, digest)
		}
	}
	if decoded.EvidenceSHA256 == decoded.ExpectedSHA256 {
		t.Fatal("vector should carry DIFFERENT evidence and expected, or a field swap passes")
	}
}

func TestCertVectors(t *testing.T) {
	priv, pub := vectorCAKey(t)
	cert := vectorCert()
	got, err := CertSigningBytes(cert)
	if err != nil {
		t.Fatalf("CertSigningBytes: %v", err)
	}
	if string(got) != certBytes {
		t.Fatalf("cert bytes drifted:\n got %q\nwant %q", got, certBytes)
	}
	sig, err := SignCert(priv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	if sig != certSig {
		t.Fatalf("cert signature drifted: got %s want %s", sig, certSig)
	}
	ok, err := VerifyCert(pub, cert)
	if err != nil || !ok {
		t.Fatalf("VerifyCert = %v, %v; want true", ok, err)
	}

	cert.Scope.Labels["env"] = "staging"
	ok, err = VerifyCert(pub, cert)
	if err != nil {
		t.Fatalf("VerifyCert(tampered): %v", err)
	}
	if ok {
		t.Fatal("tampered certificate verified")
	}
}
