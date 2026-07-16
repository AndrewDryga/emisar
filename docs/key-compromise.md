# Key-compromise response

Use this runbook when a credential may have been copied, logged, or used by an
unauthorized party. Treat uncertainty as an incident until the exposure is
bounded. Do not put the value in a ticket, shell history, audit metadata, or a
chat message.

This is the default order for a production response:

1. Preserve the evidence: record the credential, suspected exposure time, and
   affected account or environment. Freeze automated publication and unrelated
   deploys while you work.
2. Contain the credential at the system that accepts it: revoke the runner key,
   stop registry publication, or rotate the provider credential.
3. Rotate the runner trust credential first. Then rotate external-provider
   credentials at the provider before changing the application value.
4. Rotate the MCP Registry publisher key and republish its public proof.
5. Handle `SECRET_KEY_BASE`, `RELEASE_COOKIE`, DNSSEC, and the dispatch signing
   CA through their existing runbooks below. Do not combine their rollout
   ordering casually.
6. Verify the new credential, the old-credential failure path, provider
   delivery, runner reconnections, and the relevant audit events. Keep the old
   value only for a documented overlap window.

## Runner enrollment/auth keys

This is the `EMISAR_AUTH_KEY` value with an `emkey-auth-…` prefix. The portal
mints it from **Runners → Connect a runner** and stores only its hash in the
`runner_enrollment_keys` table. The operator sees the raw value once and puts it
in the host's mode-0600 `/etc/emisar/runner.env` (or the configured equivalent).
The key is presented to `POST /runner/register`.

The key is a bootstrap credential, not the credential used on every websocket
connection. Registration returns a long-lived `rnrtok-…` runner token, which the
runner stores at `cloud.token_path` (by default
`/var/lib/emisar/token.json`) and reuses on later boots. Dashboard install keys
are single-use; manually created enrollment keys may be reusable or have a
maximum use count.

### Blast radius

An attacker with a usable enrollment key can authenticate to runner
registration for its account and mint a runner token. Without a matching
external ID, the attacker can register a new runner, subject to the account's
runner limit and name constraints. With a matching external ID, the attacker
can obtain a fresh token for that runner identity and compete for its
connection. A malicious runner can receive actions targeted at it and send
runner-controlled state or results.

The key is not an operator API key, an MCP key, an SSH key, or a signed-dispatch
leaf/CA key. It does not by itself read portal data, change policy, or sign a
dispatch for a runner enforcing client signatures. It also does not give the
attacker access to the original host unless the attacker separately has that
host's token or control of the host.

### Immediate containment

1. Revoke every affected enrollment key in **Runners → Auth keys**. If one
   reusable key was installed on several hosts, treat every host using it as
   affected; do not wait for a per-host attribution.
2. Review runner-registration audit events and the fleet inventory. Disable and
   soft-delete any runner identity that was not expected. Deletion preserves
   history but makes its old runner tokens fail the normal token check.
3. If an attacker may have obtained a token for a legitimate runner identity,
   keep that identity disabled and replace it rather than simply re-enabling it:
   the repo has no token-only revocation operation, and old tokens are durable
   until the runner identity is deleted.

### Rotation and required fleet roll

For each legitimate host:

1. Mint a fresh enrollment key. Use one key per host for a fleet; do not return
   to a shared reusable key after this incident.
2. Stop the runner service before changing its credentials.
3. Replace `EMISAR_AUTH_KEY` in the host's protected environment file.
4. Remove the cached token at the configured `cloud.token_path`. If the path is
   not explicitly configured, remove `/var/lib/emisar/token.json`.
5. Start the runner and confirm that it registers with the new key, receives a
   new `rnrtok-…` token, and appears online under the expected identity. Refresh
   runner references before dispatching work.
6. Repeat for **every runner in the fleet**, including hosts that were online.
   An online runner normally reuses its cached token, so changing or revoking
   the enrollment key does not make that host re-enroll.

Do not call the rotation complete until the fleet inventory shows the new
registrations and the old key fails at `/runner/register`. If a host's old
token may have been exposed, replace its runner identity as described above;
changing only `EMISAR_AUTH_KEY` does not revoke an already-issued token.

See the runner [installation and connection notes](../runner/README.md#after-install)
for the supported host paths and service layout.

## MCP Registry publisher key

The private key is the `MCP_PRIVATE_KEY` secret in the protected GitHub
`mcp-registry-publication` environment. The
[publication workflow](../.github/workflows/mcp-registry-release.yml) accepts
an Ed25519 PEM key or a 64-hex seed, normalizes it, derives the public key, and
requires it to match the live domain proof before it runs
`mcp-publisher login http --domain emisar.dev` and publishes `server.json`.
The matching public key is committed at
[`portal/apps/emisar_web/priv/static/.well-known/mcp-registry-auth`](../portal/apps/emisar_web/priv/static/.well-known/mcp-registry-auth)
and is served by the portal at
`https://emisar.dev/.well-known/mcp-registry-auth`.

### Blast radius and immediate containment

The private key lets an attacker authenticate as the `emisar.dev` publisher
and publish a different hosted MCP Registry listing. They could redirect
discovery to a malicious MCP endpoint or alter the listing metadata. The key
does not update the portal, the well-known proof, runner enrollment keys, or
the action-pack registry by itself.

Immediately cancel pending registry-publication jobs and remove or disable the
old `MCP_PRIVATE_KEY` in the protected GitHub environment. Preserve the
workflow and registry audit records. Do not publish another listing with the
old key while preparing the replacement.

### Rotation

1. Generate a new Ed25519 key on an offline, access-controlled machine. Keep
   the private key out of the repository and CI logs. The workflow's accepted
   formats are the PEM form or a 64-hex seed; the repo contains normalization
   and verification, not a private-key storage mechanism.
2. Derive the new public key, encode the 32-byte Ed25519 public key as base64,
   and update the well-known record to exactly
   `v=MCPv1; k=ed25519; p=<new-public-key>`.
3. Deploy that record and verify it before using the new private key:

   ```sh
   curl --fail --silent https://emisar.dev/.well-known/mcp-registry-auth
   ```

   The returned `p=` value must be the new public key. This proof deployment is
   the boundary that stops the old key from publishing a listing.
4. Replace the protected GitHub environment secret with the new private key.
   Keep the environment approval gate enabled.
5. Run the workflow's manual recovery path for an existing immutable `vX.Y.Z`
   release. It revalidates the live proof, validates the listing, and republishes
   the known release source. Verify the registry listing's URL, version, and
   content after publication.
6. Remove every old private-key copy and record the old-key publication review.

The repo does not document a separate provider-side revoke command for the MCP
Registry account. If the registry provider exposes one, use it during step 1;
the repository-confirmed revocation path is replacing the live domain proof.

## External-provider credentials

The application receives these values from sensitive HCP Terraform workspace
variables. Terraform writes exact Secret Manager versions, and the rendered
cloud-init names the version explicitly. A variable edit without incrementing
the matching `local.secret_generations` entry is not a reliable rotation.
Follow [infra's Secrets procedure](../infra/README.md#secrets): update one
credential's generation, review the HCP plan, apply it, and watch the managed
instance group roll to healthy VMs.

The ordering for every provider credential is **provider first, application
second**:

1. At the provider, revoke, replace, or regenerate the exposed credential.
   Confirm the provider accepted the new value and note any delivery overlap
   window.
2. Update the matching sensitive HCP Terraform variable.
3. Increment only that secret's generation in `infra/secrets.tf`, then run the
   reviewed infrastructure plan and apply.
4. Verify the provider path against the new app version. After the overlap
   window and delivery backlog are clear, revoke the old provider value if the
   provider did not revoke it as part of replacement.

### Paddle webhook secret

**Blast radius.** `PADDLE_WEBHOOK_SECRET` authenticates the HMAC on
`/webhooks/paddle`. A person with it can forge billing events that pass
signature verification and reach the subscription/entitlement application
path. If the incident may include the Paddle API key or client token, rotate
those separate Paddle credentials in the same incident; billing is configured
as an all-or-nothing set in production.

**Containment and rotation.** Rotate or revoke the webhook signing secret in
Paddle first, then follow the application update steps above. Keep the old and
new webhook secrets accepted during the provider's overlap window so in-flight
or retried events are not rejected.

The current application has one `PADDLE_WEBHOOK_SECRET` environment value and
the verifier accepts one secret; no dual-secret application setting is
confirmed here. If Paddle cannot provide an overlap that this deployment can
honor, stop before the cutover and resolve that application gap. Do not
silently replace the value and assume retries will be harmless.

### Postmark

**Blast radius.** `POSTMARK_API_TOKEN` is used for outbound mail.
`POSTMARK_WEBHOOK_SECRET` is the HTTP Basic Auth password for the
bounce/complaint webhook; an attacker with the latter can submit authenticated
suppression events.

**Containment and rotation.** Rotate the exposed token or webhook password in
Postmark first, then update the corresponding HCP variable and generation.
Verify both a real mail send and the webhook behavior.

The app currently has one `POSTMARK_WEBHOOK_SECRET` value and does not expose a
dual-password overlap setting. Coordinate a short provider cutover and verify
delivery rather than inventing a second environment variable.

### Sentry DSN

**Blast radius.** `SENTRY_DSN` is an event-ingestion credential. An attacker
can inject noise or false errors into the configured Sentry project; the DSN
alone is not the project's administrative credential.

**Containment and rotation.** Rotate or disable the DSN in Sentry first, then
update `sentry_dsn` and its generation. Verify that a controlled error is
accepted under the new DSN and that the old DSN no longer ingests, if Sentry's
credential model supports that check.

### Mixpanel project token

**Blast radius.** `MIXPANEL_TOKEN` authenticates server-side event, profile,
and group writes. An attacker can poison product analytics with forged data;
the token is not a portal login.

**Containment and rotation.** Rotate or revoke it in Mixpanel first, then
update `mixpanel_token` and its generation. Verify one controlled event and
that the old token is no longer accepted where the provider exposes that
signal.

The repository confirms the application-side provisioning for all four
providers, but it does not contain provider-specific rotation commands or
confirm each provider's overlap semantics. Use the provider's current
credential procedure for step 1 and record the provider-side result; do not
treat an HCP Terraform apply as provider rotation.

## Existing internal rotation runbooks

Use these procedures instead of copying their mechanics into this page:

- [Dispatch signing CA — rotating and revoking](signed-dispatch.md#rotating-and-revoking):
  add the replacement CA, reload with `SIGHUP`, re-issue certificates, then
  remove the old CA and reload again.
- [Portal `SECRET_KEY_BASE` and `RELEASE_COOKIE`](../infra/README.md#secrets):
  separate generations and separate rollouts; the release cookie must stay
  identical across the serving cluster during its staged cutover.
- [DNSSEC](../infra/README.md#dns-and-dnssec):
  activate the child key before publishing the replacement parent DS, and keep
  the old DS until resolver convergence.
