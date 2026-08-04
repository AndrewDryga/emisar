# Packs: suggestions use explicit evidence

## Rule

Build pack suggestions only from the pack's explicit `detect` declaration.
Never infer detection binaries from `requires.binaries`. A pack without authored
detection evidence is omitted from host suggestions.

A suggestion also needs evidence that identifies the service: a declared
service-specific binary present, or a declared process running. A listening port
corroborates a pack those signals already matched; it never qualifies one on its
own, and a pack declaring only ports is not auto-suggested.

## Why

Requirements answer whether an installed action can execute, not whether its
target exists on this host. Generic helpers such as `timeout` and `base64`, and
configuration-dependent clients such as `git`, otherwise turn ordinary base
images into confident but false Nomad, OIDC, and repository recommendations.
Maintaining exception lists only moves the next false positive into production.

A listening socket carries no owner identity. Any process may bind the port a
pack declares — a proxy, a tunnel, a test server, or a different service that
conventionally uses it — so a port alone vouches for every pack declaring that
number. Binaries and processes are named by the host itself, which is what makes
them identity.

## Good

```yaml
requires:
  binaries: [nomad, jq, timeout]
detect:
  processes: [nomad]
  ports: [4646]
```

Only the authored Nomad evidence enters `suggest.json`; helper dependencies do
not. The running `nomad` process recommends the pack, and `:4646` joins the
evidence as corroboration.

## Bad

```text
detect.binaries = requires.binaries - known_generic_helpers
```

The exception list incorrectly treats every unknown dependency as service
identity.

```yaml
detect:
  ports: [5432]
```

Any local listener on that port — a database proxy, an SSH tunnel — would
recommend this pack, and would recommend every other pack declaring the same
port at the same time.

## Sweep

Search catalog builders, suggestion matchers, and local-catalog paths for
fallbacks from `requires.binaries` into `detect.binaries`, and for match logic
that treats port hits as qualifying rather than corroborating. Review packs
declaring only ports, and packs with no `detect` block, as intentionally manual.

## Enforcement

`runner/internal/catalog/catalog_test.go` builds a pack requiring `git`,
`timeout`, `base64`, and a service-looking binary without a `detect` block and
asserts that none appears in its detection metadata or suggestion index.
`runner/internal/hostscan/hostscan_security_test.go` asserts that listeners on
declared ports suggest no pack when nothing identifies the service, and
`hostscan_test.go` covers ports corroborating a process match.
