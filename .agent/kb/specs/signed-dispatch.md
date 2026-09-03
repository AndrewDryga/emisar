# Signed dispatch (bridge-attested dispatch)

A runner can be told to **refuse the control plane's authority**: with signing
enforced, it executes an action only if the dispatch carries a valid signature
from an Ed25519 or ECDSA P-256 leaf key held by a customer-authorized MCP bridge
— and that signature is vouched for by a **certificate** issued by a trusted,
offline certificate authority. The control plane **relays** the signature and
the certificate; it holds no private key, so it cannot forge or alter one, widen
its signed runner set, or originate a valid signed run. A preserved replay
journal prevents nonce reuse on that runner identity. A replacement that reuses
the external ID must preserve that state or rotate its identity and trust
material.

This is the strongest defense emisar offers against a compromised control plane.
It is **opt-in per runner** and a deliberate trade: while it's on, the portal,
runbooks, scheduled runs, and API keys **cannot dispatch to that runner** — only
a signed MCP call runs.

## Why a certificate authority

A runner trusts **one certificate authority**, not a list of individual operator
keys. The CA — a keypair you generate and keep **offline**, or one your own PKI
already holds — issues short-lived X.509 certificates that vouch for each
operator's signing key. So:

- **Onboarding an operator is one signature, zero runner edits.** You mint them a
  certificate with the CA; every runner that already trusts the CA accepts it.
  You never touch a runner's config to add a person.
- **The CA private key never touches a runner or the control plane.** A
  compromised portal can relay a certified dispatch but can never mint one —
  that's the whole point.
- **Revocation is the certificate's lifetime.** There is no CRL and no OCSP:
  certificates are short-lived (24h by default), and a leaked key is useless
  once its certificate expires. You
  revoke by not re-issuing.

## When to use it

- A high-trust host where "this came from a customer-authorized MCP bridge"
  must be cryptographically true, not merely asserted by the control plane.
- **Not** for runners you drive from the portal Run button or from runbooks:
  those stop working against an enforcing runner (by design).

## How it works

1. The MCP bridge signs a fixed v5 JSON claim for `run_action`: canonical portal
   origin, exact action ID and immutable `pack_ref`, SHA-256 of the exact JSON
   argument bytes, SHA-256 of the complete sorted identity-bound runner refs,
   exact reason, SHA-256 of the `evidence` and `expected` narrative, bridge
   operation ID, one-time nonce, and timestamp.

   The narrative is bound by DIGEST rather than carried: together those two
   fields run to 6,000 characters against a 16 KiB envelope, and the argument
   bytes already establish that a large field is signed as a hash. Both are
   optional and both are always hashed — an absent one signs as the digest of
   the empty string. This binds the narrative the bridge supplied. The portal
   compares the text it accepts with those signed digests. The runner receives
   only the digests, not the narrative text, so signing does not independently
   authenticate what a compromised portal renders to an approver. v4 signed what
   runs; v5 also binds the bridge-supplied evidence and expected result. The
   **leaf private key** never leaves the operator's machine. The bridge
   never decodes and re-encodes the action arguments, so values above `2^53`,
   exponent spellings, object order, and escapes remain exactly what was signed.
2. The portal bounds and stores the known envelope fields, resolves the selected
   refs, requires that exact set and all preflight operation facts to match the
   signed claim, compares `evidence` and `expected` with their signed digests,
   and relays the claim with the exact argument bytes. It cannot
   change the action, pack, args, reason, operation, origin, or target set without
   invalidating the signature, cannot alter the CA-signed certificate, and has
   no key to mint either.
3. The runner verifies, in order: the certificate is signed by a CA it trusts →
   the certificate is inside its validity window → this runner's identity suffix,
   derived from its local external ID, occurs exactly once in the signed target
   set → the signed
   portal origin, action, immutable pack bytes, exact arguments, reason, and
   operation match the delivered dispatch → the certificate's **scope** matches
   this runner's own group/labels → the attestation is inside the freshness
   window → the attestation signature verifies under the **leaf key the
   certificate vouches for** → the nonce has not been seen. Only then does it run.
   Anything else is refused.

The v5 signature binds the **exact runner set** with refs shaped as
`name~first32hex(sha256(external_id))`. The runner independently verifies the
identity suffix against its local external ID; the name remains portal-owned
display context. A compromised relay cannot add another runner identity after
the bridge signs. The certificate's scope is an independent, coarser ceiling
asserted by the offline CA and matched against each runner's local
`group`/`labels`. A scoped certificate
(`group=prod`) still cannot run outside that scope; an empty-scope certificate
means the signed target set may contain any runner that trusts the CA.

The certificate's validity window and the attestation's freshness window are
**independent gates** — a long-lived certificate never widens the replay window.

## The certificate profile

Certificates are X.509, so a customer PKI (Vault PKI, AD CS, step-ca, an
HSM-backed CA) can issue them instead of the CLI. A runner accepts a chain only
when every rule below holds; a violation refuses the dispatch as
`cert_profile`.

| Rule | Why |
|---|---|
| Exactly ONE URI SAN, `emisar://dispatch/v1` with the canonical query below | This is what marks a certificate as issued FOR emisar. A TLS server certificate from the same corporate CA has no such SAN, so a shared root cannot turn server certificates into dispatch-signing authority. |
| Leaf key is Ed25519 or ECDSA P-256 | P-256 exists because several major KMS and HSM products still do not offer Ed25519, and HSM custody of the CA is a first-class case. |
| Leaf is not a CA (`BasicConstraints` CA false) | A CA certificate signing dispatches would blur issuance and use. |
| If `KeyUsage` is present it includes `digitalSignature` | An issuer that states the usage must state one that permits signing. |
| Chain of at most leaf + one intermediate | Deeper chains are refused even when they verify; pin the deeper issuer as the anchor instead. |
| Inside its validity window, no skew tolerance | Expiry is the whole revocation story, so it is judged exactly. |

No EKU is required: emisar owns no OID arc, and requiring a borrowed EKU
(`serverAuth`) would accept exactly the TLS certificates the SAN exists to
exclude.

A customer can go further and name-constrain an intermediate to `emisar://`
URIs, which makes even a shared corporate root safe by construction.

### Scope, as a URI SAN

Scope rides in the SAN's query, in ONE canonical spelling — a URI that parses
but is spelled differently is refused rather than normalized, so an issuer and a
verifier can never disagree about what was authorized.

```
emisar://dispatch/v1[?<params>]

params = param *( "&" param )        ; sorted bytewise, no duplicates
param  = "group=" value / "label." key "=" value
```

Keys and values are percent-encoded on the same terms: anything outside RFC 3986
`unreserved` is encoded, with uppercase hex and minimal encoding. Keys are
encoded too because a runner label key is free-form operator input —
`runner.labels` is a bare YAML map plus `EMISAR_RUNNER_LABEL_<KEY>` env, with no
charset the config layer enforces. No query at all means the empty scope: valid
on any runner that trusts the anchor.

The whole URI is bounded at 512 bytes.

Matching happens ONLY against the runner's local `runner.group` /
`runner.labels`, never a value the control plane supplies — that is the
redirect guard. A label pinned to the empty string still requires the runner to
CARRY that label; it does not match a runner that lacks it.

## Turn it on — the quickstart

Run this on the runner host, or on any offline machine (the keys are generated
locally and the private ones are sent nowhere):

```sh
emisar signing init
```

It mints a CA, a leaf key, and a 24h certificate in one step, and prints: the
`signing:` block for the runner config (the CA **certificate**, safe to commit),
the CA **private** key to store offline, and the two MCP env vars.

1. **Install the CA in the runner config** (`/etc/emisar/config.yaml`):

   ```yaml
   signing:
     enforce_signatures: true
     max_attestation_age: 24h
     trusted_cas:
       - name: emisar-dispatch-ca
         pem: |
           -----BEGIN CERTIFICATE-----
           <the CA certificate the command printed>
           -----END CERTIFICATE-----
   ```

   `name` is a display label the runner advertises so an operator can confirm
   which anchors a host accepts; trust comes from the certificate alone.

2. **Store the CA private key offline** — a vault or an operator's machine, never
   a runner and never the control plane. You re-sign certificates with it as they
   expire.

3. **Give the MCP bridge the two env vars** (see [`mcp/README.md`](../../../mcp/README.md)) — never
   on the portal, never in version control:

   ```sh
   EMISAR_SIGNING_KEY=<base64 PKCS#8 private key from the command>
   EMISAR_SIGNING_CERT=<base64 PEM certificate chain from the command>
   ```

4. **Apply it.** Restart the runner. Initial enforcement opens the durable replay
   journal at startup before any signed dispatch can be accepted. Once enforcement
   is active, later CA rotation or revocation takes effect live with `SIGHUP`.

5. **Verify:** the portal's Runner page shows **"Signed dispatch only"** and the
   Run button is disabled; an MCP `tools/call` runs; an operator/runbook dispatch
   is refused with a clear message.

## Onboarding more operators and runners

- **A new operator** (the CA already exists): mint them a certificate — no runner
  change at all.

  ```sh
  emisar signing new-cert --ca-key-file <path to the CA private key> \
    --ca-cert <CA certificate> --key-name op-alice --scope group=prod --ttl 24h
  ```

  Pass the CA private key as a file. The `--ca-key` flag takes the key material
  itself, which puts the root of trust for signed dispatch into shell history and
  into `/proc/<pid>/cmdline`, where any other user on the host can read it while
  the command runs. It stays for the scripts that already use it, and passing both
  is refused rather than resolved.

  It mints a new leaf key and prints `EMISAR_SIGNING_KEY` +
  `EMISAR_SIGNING_CERT` for that operator. To certify an existing or HSM-held
  leaf key, issue the certificate through your own PKI using the profile above.

- **A new runner**: add the same `trusted_cas` block to its config and restart it.
  Every operator holding a CA-issued certificate in that runner's scope can
  already reach it.

- **`emisar signing new-ca`** mints just the CA, when you want to generate it once and
  certify leaf keys separately from standing up the first runner.

## Scope — restricting where a certificate is valid

`--scope` binds a certificate to runners by their **local** identity:

- `--scope group=prod` — valid only on runners whose `runner.group` is `prod`.
- `--scope group=prod,region=us` — also requires the runner to carry label
  `region=us`.
- empty (the default if `--scope` is omitted) — valid on any runner that trusts
  the CA.

The runner first requires exactly one ref with its identity suffix in the
per-call signed target set, then matches certificate scope against its **own**
configured group/labels. Scope is
defense in depth and a useful blast-radius ceiling; it no longer substitutes for
binding the operator's exact selection.

## Rotating and revoking

Certificates are short-lived, so the normal path is **re-issue, not reconfigure**:

1. **Renew.** Before a certificate expires, mint a fresh one (`emisar signing new-cert …`)
   and update the operator's `EMISAR_SIGNING_CERT`. Automate it on a schedule
   shorter than `--ttl`.
2. **Revoke an operator.** Stop re-issuing their certificate; once the current
   one expires (≤ `--ttl`) they can no longer dispatch. For an immediate cutover,
   rotate the CA (below). There is no CRL yet — short TTLs *are* the revocation
   mechanism.
3. **Rotate the CA** with no downtime — `trusted_cas` is a list, so it's
   add-then-remove and `SIGHUP` applies each step live:
   - Add the new CA alongside the old, `SIGHUP` (both are now trusted).
   - Re-issue operator certificates under the new CA.
   - Remove the old CA from the runner config, `SIGHUP` again.

A **long `--ttl`** (e.g. `1y`, for a solo or break-glass setup) trades away that
revocation granularity — there's no way to retract a long-lived certificate short
of rotating the CA. Prefer short TTLs with automated renewal.

## Accepted limitations

Be clear-eyed about what this does and doesn't guarantee:

- **Integrity, not availability.** A compromised control plane can still
  *withhold* or refuse to relay a signed dispatch. Signing stops it from
  *forging* one; it does not force it to deliver yours.
- **Discovery names come from the portal.** The signature binds identity
  suffixes derived from external runner IDs; it does not make the display-name
  prefix truthful. A compromised portal can lie while presenting that mapping
  before the call is signed. Use narrow certificate scopes and verify suffixes
  out of band for the highest-trust workflows.
- **Approval text comes from the portal.** The portal verifies `evidence` and
  `expected` against the signed digests before it accepts an ordinary request,
  but the runner never receives the narrative text. A compromised portal can
  render different text to an approver. Verify the bridge-supplied narrative out
  of band when approval-screen integrity must not depend on the control plane.
- **Replay journal durability.** Enforcement requires `paths.data_dir`. The
  runner appends and fsyncs each accepted nonce under that directory before it
  admits the dispatch; every hot-reloaded verifier shares the same live store.
  Expired records are periodically compacted with a synced atomic rename. The
  journal is capped at 100,000 fresh nonces and 16 MiB; reaching either bound
  refuses new dispatches without evicting a still-fresh nonce. A restart reloads
  the same state. Unreadable, corrupt, torn, full, or unwritable state fails
  closed with `nonce_store_unavailable` rather than reopening replay.
  A replacement that reuses the same external ID must also preserve this
  journal. Otherwise rotate the runner identity and trust material before use.
- **Choose the freshness horizon up front.** The journal persists the largest
  `max_attestation_age` it may safely protect. Narrowing and later restoring that
  value is safe because records remain for the persisted horizon; increasing it
  beyond that horizon is rejected on reload and restart. To increase it, rotate
  every trusted CA first, stop the runner, remove the nonce journal, update the
  value, and restart. Rotating trust makes every attestation from the discarded
  replay history unverifiable.
- **Queued-while-offline.** A dispatch that sits queued (runner offline) longer
  than `max_attestation_age` — or past the certificate's `valid_until` — is
  refused and must be re-issued.
- **Approvals + signing.** A signed run that hits a `require_approval` policy is
  parked; on approval it is re-dispatched with its **original** signature and
  certificate. At that point it must still be inside **both** the
  `max_attestation_age` freshness window **and** the certificate's validity
  window, or the runner refuses it. If you combine signing with approvals, set
  both comfortably above your approval SLA — at the cost of a longer replay
  window.

See [`security-model.md`](security-model.md) for how this sits in the
overall threat model.

## Troubleshooting a refusal

A refused dispatch comes back as a **failed** run whose error message names the
cause. The runner's refusal codes:

| Code | Meaning | Fix |
| --- | --- | --- |
| `signature_required` | The dispatch carried no signature or no certificate (it came from the portal/runbook/API, or the MCP bridge isn't configured to sign). | Run it through an MCP bridge with `EMISAR_SIGNING_KEY` **and** `EMISAR_SIGNING_CERT` set. |
| `attestation_version` | The envelope is not the supported `emisar-attestation-v5` format. | Upgrade the MCP bridge and submit a fresh call. |
| `attestation_tool` | The signed claim is not for the literal `run_action` tool. | Upgrade or repair the MCP bridge; do not retry the altered claim. |
| `portal_mismatch` | The signed portal origin differs from the runner's configured control-plane origin. | Point the client and runner at the same canonical control-plane origin and submit a fresh call. |
| `intent_mismatch` | The action, pack, exact args, reason, or operation differs from the signed intent. | Refresh the action and runner refs, then submit a fresh call; do not reuse the altered envelope. |
| `target_mismatch` | This runner generation is absent or appears more than once in the signed runner-ref set. | Refresh discovery and submit a fresh call with the exact returned runner refs. |
| `cert_profile` | The certificate does not satisfy the emisar profile: no `emisar://dispatch/v1` SAN (a TLS-shaped certificate), several of them, a non-canonical scope query, a CA certificate used as a leaf, an unaccepted key algorithm, or a chain deeper than one intermediate. | Re-issue against the profile above; a certificate from a general-purpose CA does not carry dispatch-signing authority. |
| `cert_untrusted` | The chain does not verify to any certificate in this runner's `trusted_cas`. | Point the client at a certificate issued by an anchor this runner trusts, or add the anchor to `trusted_cas` (and `SIGHUP`). |
| `cert_expired` | The certificate's validity window doesn't include now (expired, not yet valid, or clock skew). | Re-issue the certificate (`emisar signing new-cert`); check host clocks (NTP). |
| `cert_scope` | The certificate's scope (group/labels) isn't satisfied by this runner's local `group`/`labels`. | Issue the certificate with a scope matching this runner (or an empty scope), or dispatch to a runner in scope. |
| `stale` | The attestation's timestamp is outside `±max_attestation_age` (clock skew, a long-queued run, or a slow approval). | Re-issue the run; check host clocks; if approvals routinely exceed the configured window, follow the CA-rotation procedure above before increasing it. |
| `bad_signature` | The signature doesn't verify against the action, exact args, target set, nonce, and time under the certificate's leaf key. | Refresh tools and re-submit with the matching key/certificate pair; re-mint with `emisar signing new-cert` if the pair is wrong. |
| `replayed` | This nonce was already used. | The client double-sent; re-issue with a fresh dispatch. |
| `nonce_store_unavailable` | The runner couldn't safely retain the nonce (the replay journal is unavailable, corrupt, or at capacity). | Fix the runner's data-dir permissions/disk or capacity; the runner refuses rather than risk a replay after a restart. |
| `invalid_args` | The dispatch's argument bytes are not one well-formed JSON object, so no exact-args digest can be formed. | Refresh discovery and submit a fresh call; do not hand-edit the arguments. |
| `bad_nonce` | The envelope's nonce is not 32 lowercase hex characters. | Upgrade or repair the MCP bridge; do not retry the altered envelope. |
| `bad_issued_at` | The envelope's `issued_at` is not a parseable RFC3339 timestamp. | Upgrade or repair the MCP bridge; check the client's clock. |
| `dispatch_invalid` | The dispatch frame itself was malformed before signature checking began. | Upgrade the control plane and the bridge; re-issue the run. |
