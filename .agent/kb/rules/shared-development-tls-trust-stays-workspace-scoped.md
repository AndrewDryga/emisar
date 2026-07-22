# Rule: development TLS trust stays workspace-scoped

**Rule.** Development certificate trust operations identify the active
workspace CA by exact fingerprint, and automated browser exceptions permit only
the current leaf certificate's SPKI. Never delete trust by a shared certificate
name or disable TLS validation globally. Certificate rotation goes through the
development command that also recreates processes holding the old material.

**Why.** Parallel workspaces can use identical certificate names while carrying
different keys. Name-based deletion can remove another workspace's trust, and a
global browser bypass hides certificate, hostname, and interception failures far
beyond the development sidecar being tested.

**Good.** `dev/run certs untrust` removes one generated CA fingerprint;
automated Chromium receives one `--ignore-certificate-errors-spki-list` value;
renewal recreates Keycloak when its leaf changes.

**Bad.** Delete every keychain certificate with the development CA common name,
launch Chromium with a global certificate-error bypass, or replace generated
files while leaving the sidecar running.

**Sweep.** Search development certificate and browser launch tooling for
common-name deletion, broad certificate-error flags, manual generated-file
instructions, and rotations that omit dependent process recreation.

**Enforced.** Browser resolver tests pin the SPKI-scoped launch arguments;
`dev/run` tests and review cover exact-fingerprint trust mutation and sidecar
recreation.
