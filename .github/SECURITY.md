# Security policy

## Reporting a vulnerability

If you find a security issue in emisar, please **do not file a public
GitHub issue**. Instead:

- Email **security@dryga.com** with the details, or
- Use GitHub's [private vulnerability reporting](https://github.com/andrewdryga/emisar/security/advisories/new).

Include:

- A description of the issue and the impact you observed.
- A minimal reproduction (or pointer to the relevant code path).
- The version / commit SHA you tested against.
- Whether you'd like attribution in the fix.

You'll get an acknowledgement within **72 hours**. We aim to ship a
fix or a documented mitigation within **14 days** for high-severity
issues. Coordinated disclosure on a public advisory is the default.

## Supported versions

Until `v1.0`, only the latest tagged release receives security fixes.
Older versions may be patched at our discretion if the issue is severe
and the upgrade path from older versions is non-trivial.

| Version  | Supported          |
| -------- | ------------------ |
| latest   | :white_check_mark: |
| < latest | :x: (please upgrade) |

## Threat model

See [`docs/security-model.md`](docs/security-model.md) for the
deliberate scope: what emisar protects against, what it does NOT
protect against, and what operators are expected to provide.

The short version: emisar is a **policy and audit envelope** around a
curated allowlist of declared actions. It is not a sandbox, container
runtime, or kernel isolation layer. Reports that boil down to
"`linux.systemctl_restart` actually restarts the service" are working
as intended; we won't accept those as vulnerabilities. Reports that
the runner executed something it should have refused are.

## Out of scope

The following are intentionally not vulnerabilities:

- Actions doing exactly what their YAML declares.
- The runner running OS commands that require root, when the operator
  has granted it root.
- Operator misconfiguration (e.g., wide `allowed_prefixes` exposing
  `/etc/shadow`) that the runner honours.
- Denial-of-service via the cloud control plane sending the runner too
  many actions — that's a cloud-side rate-limit concern, not an runner
  bug.

## In scope

The following are real vulnerabilities:

- The runner executing an action whose **declared args don't pass
  validation** (schema bypass).
- The runner **executing an unknown action ID** or one without a valid
  pack.yaml reference.
- The runner **honouring shell metacharacters** as if they were
  interpreted (we never run a shell — if we accidentally do, that's a
  bug).
- A **path traversal** escape of the runner's declared allow/deny
  rules — including symlink-based redirects (since we now resolve
  symlinks during validation).
- **Output leaking secrets** that the redactor was supposed to catch
  (where "supposed to" means the redactor has a rule for that
  pattern).
- The runner **executing a script** whose on-disk SHA-256 doesn't match
  the cached value from load time (this would be a tampered binary;
  we should refuse to run, but currently re-checking script SHA at
  execution time is a known TODO — surface it if you find a way to
  trigger).
- **Privilege escalation** through the runner's process attributes
  (failure of Pdeathsig + Setpgid hardening, leaking caps to children).
- **Outbox / dedup ring** corruption that causes a result to be sent
  for a request the runner never received.

## Defence-in-depth choices we already made

These are not vulnerabilities to report — they're how the runner is
designed:

- No inbound listener; the runner dials out to cloud.
- No shell-kind action exists in the schema.
- argv arrays only; never `sh -c "..."`.
- Per-action declared limits with min/max bounds; cloud opts are
  clamped at the runner.
- Bearer-token / AWS-key / private-key default redactions on every
  action's output before it leaves the runner.
- JSONL security log written on every attempt (success, failure,
  validation_failed, error) — append-only locally.
- systemd unit hardening (no new privileges, protect system, protect
  kernel, restrict namespaces, system-call filter).

If you spot a gap in this list, please report it via the channels
above.

## Safe harbor

If you make a good-faith effort to comply with this policy, we will
not pursue legal action against you for accidental, good-faith
security research activity that is limited to identifying and
reporting vulnerabilities.

This safe harbor does not authorize:

- extortion;
- data theft;
- persistence;
- malware;
- denial of service;
- privacy violations;
- social engineering;
- physical attacks;
- attacks against third-party services;
- violations of law.

## License of security reports

Security reports and related submissions are Contributions and are
subject to [`CONTRIBUTING.md`](./CONTRIBUTING.md), [`CLA.md`](./CLA.md)
if applicable, and the repository [`LICENSE.md`](./LICENSE.md) unless
separately agreed in writing.
