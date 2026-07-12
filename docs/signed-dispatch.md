# Signed dispatch (client-attested dispatch)

A runner can be told to **refuse the control plane's authority**: with signing
enforced, it executes an action only if the dispatch carries a valid Ed25519
signature a real person produced in their own MCP client — and that signature is
vouched for by a **certificate** issued by a trusted, offline certificate
authority. The control plane **relays** the signature and the certificate; it
holds no private key, so it can neither forge, alter, redirect, nor replay one,
and it cannot originate a run at all. The signature, not the cloud, is the
authority.

This is the strongest defense emisar offers against a compromised control plane.
It is **opt-in per runner** and a deliberate trade: while it's on, the portal,
runbooks, scheduled runs, and API keys **cannot dispatch to that runner** — only
a signed MCP call runs.

## Why a certificate authority

A runner trusts **one certificate authority**, not a list of individual operator
keys. The CA — an Ed25519 keypair you generate and keep **offline** — signs
short-lived certificates that vouch for each operator's signing key. So:

- **Onboarding an operator is one signature, zero runner edits.** You mint them a
  certificate with the CA; every runner that already trusts the CA accepts it.
  You never touch a runner's config to add a person.
- **The CA private key never touches a runner or the control plane.** A
  compromised portal can relay a certified dispatch but can never mint one —
  that's the whole point.
- **Revocation is the certificate's lifetime.** Certificates are short-lived
  (24h by default); a leaked key is useless once its certificate expires. You
  revoke by not re-issuing.

## When to use it

- A high-trust host where "a real human asked for this, in their LLM client"
  must be cryptographically true — not just policy-checked.
- **Not** for runners you drive from the portal Run button or from runbooks:
  those stop working against an enforcing runner (by design).

## How it works

1. The MCP client signs a canonical message — the action id, its arguments, a
   one-time nonce, and a timestamp — with an Ed25519 **leaf** private key that
   never leaves the operator's machine, and attaches the **certificate** the CA
   issued for that key.
2. The portal stores and relays both verbatim. It can't change the action or args
   without invalidating the signature, can't alter the CA-signed certificate, and
   has no key to mint either.
3. The runner verifies, in order: the certificate is signed by a CA it trusts →
   the certificate is inside its validity window → the certificate's **scope**
   matches this runner's own group/labels → the attestation is inside the
   freshness window → the attestation signature verifies under the **leaf key the
   certificate vouches for** → the nonce hasn't been seen. Only then does it run.
   Anything else is refused.

The **runner-target binding is the certificate's scope**, asserted by the offline
CA and matched only against this runner's own local `group`/`labels` — never any
value the control plane supplies. A scoped certificate (`group=prod`) can't be
relayed to a runner outside that scope; an empty-scope certificate is the
explicit "valid on any runner that trusts the CA" mode.

The certificate's validity window and the attestation's freshness window are
**independent gates** — a long-lived certificate never widens the replay window.

## Turn it on — the quickstart

Run this on the runner host, or on any offline machine (the keys are generated
locally and the private ones are sent nowhere):

```sh
emisar signing init
```

It mints a CA, a leaf key, and a 24h certificate in one step, and prints: the
`signing:` block for the runner config (the CA **public** key, safe to commit),
the CA **private** key to store offline, and the two MCP env vars.

1. **Install the CA in the runner config** (`/etc/emisar/config.yaml`):

   ```yaml
   signing:
     enforce_signatures: true
     max_attestation_age: 24h
     trusted_cas:
       - ca_id: ca-1a2b3c4d
         public_key: <hex from the command>
   ```

2. **Store the CA private key offline** — a vault or an operator's machine, never
   a runner and never the control plane. You re-sign certificates with it as they
   expire.

3. **Give the MCP client the two env vars** (see [`docs/mcp.md`](mcp.md)) — never
   on the portal, never in version control:

   ```sh
   EMISAR_SIGNING_KEY=<hex seed from the command>
   EMISAR_SIGNING_CERT=<cert JSON from the command>
   ```

4. **Apply it.** Send the runner `SIGHUP` (or restart it): it rebuilds the
   verifier from config and re-advertises, so enabling enforcement — and every
   later change — takes effect live, no restart required.

5. **Verify:** the portal's Runner page shows **"Signed dispatch only"** and the
   Run button is disabled; an MCP `tools/call` runs; an operator/runbook dispatch
   is refused with a clear message.

## Onboarding more operators and runners

- **A new operator** (the CA already exists): mint them a certificate — no runner
  change at all.

  ```sh
  emisar signing new-cert --ca-id ca-1a2b3c4d --ca-key <CA private key> \
    --key-id op-alice --scope group=prod --ttl 24h
  ```

  It prints `EMISAR_SIGNING_KEY` + `EMISAR_SIGNING_CERT` for that operator. If
  the operator already has a leaf keypair, pass `--pubkey <hex>` and it certifies
  that key instead of minting one.

- **A new runner**: add the same `trusted_cas` block to its config and `SIGHUP`.
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

The runner matches scope against its **own** configured group/labels, so a
compromised portal can't redirect a certified dispatch to a runner the CA didn't
scope it for. This is the redirect protection a single fleet-wide key would
otherwise trade away.

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
- **Replay cache durability.** The seen-nonce cache is persisted under the
  runner's data dir, so a restart or `SIGHUP` rebuild keeps refusing a replayed
  nonce rather than forgetting it. The runner **fails closed**: if that store
  can't be read at startup it refuses to start, and if a nonce can't be durably
  recorded at dispatch time the dispatch is refused (`nonce_store_unavailable`)
  rather than risk a post-restart replay.
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

See [`docs/security-model.md`](security-model.md) for how this sits in the
overall threat model.

## Troubleshooting a refusal

A refused dispatch comes back as a **failed** run whose error message names the
cause. The runner's refusal codes:

| Code | Meaning | Fix |
| --- | --- | --- |
| `signature_required` | The dispatch carried no signature or no certificate (it came from the portal/runbook/API, or the MCP client isn't configured to sign). | Run it from an MCP client with `EMISAR_SIGNING_KEY` **and** `EMISAR_SIGNING_CERT` set. |
| `cert_untrusted` | The certificate's `ca_id` isn't in this runner's `trusted_cas`, or its CA signature doesn't verify. | Point the client at a certificate issued by a CA this runner trusts, or add the CA to `trusted_cas` (and `SIGHUP`). |
| `cert_expired` | The certificate's `valid_from`..`valid_until` window doesn't include now (expired, not yet valid, or clock skew). | Re-issue the certificate (`emisar signing new-cert`); check host clocks (NTP). |
| `cert_scope` | The certificate's scope (group/labels) isn't satisfied by this runner's local `group`/`labels`. | Issue the certificate with a scope matching this runner (or an empty scope), or dispatch to a runner in scope. |
| `stale` | The attestation's timestamp is outside `±max_attestation_age` (clock skew, a long-queued run, or a slow approval). | Re-issue the run; check host clocks; widen `max_attestation_age` if approvals are the cause. |
| `bad_signature` | The signature doesn't verify against the action, args, nonce, and time under the certificate's leaf key. | Wrong key/certificate pair — re-mint with `emisar signing new-cert`. (The MCP client refuses to start if the key and certificate don't match.) |
| `replayed` | This nonce was already used. | The client double-sent; re-issue with a fresh dispatch. |
| `nonce_store_unavailable` | The runner couldn't durably record the nonce (the replay cache is unwritable). | Fix the runner's data-dir permissions/disk; the runner refuses rather than risk a replay after a restart. |
