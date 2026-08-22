# Packs: suggestions use explicit evidence

## Rule

Build pack suggestions only from the pack's explicit `detect` declaration.
Never infer detection binaries from `requires.binaries`. A pack without authored
detection evidence is never suggested on evidence.

It still appears in `suggest.json`. The index is a plain projection of the
catalog; the matcher on the host, not the publisher, decides what this host is
offered.

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

The index stays complete because a publish-side filter over what the matcher may
consider silently disables matcher-side policy. Dropping signal-less packs from
`suggest.json` also dropped the read-only core — `linux-core`, `debugging`,
`systemd-deep` are services of nothing and declare no signal — so the baseline
that recommends them on every host could never resolve a single one, while its
code and its `--help` both said it always did. Filtering costs kilobytes and
buys nothing: a pack with an empty signal identifies nothing, so the matcher
already passes it over.

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
Check every index builder for a filter on the presence of evidence — the two
independent ones (`Catalog.Suggest`, `PublishedRegistry.suggest_index`) must
project every pack.

## Enforcement

`runner/internal/catalog/catalog_test.go` builds a pack requiring `git`,
`timeout`, `base64`, and a service-looking binary without a `detect` block and
asserts it is listed with an empty signal, never one derived from those
requirements. `portal/apps/emisar_web/test/emisar_web/packs_test.exs` asserts
the same shape over `/packs/suggest.json`, and that the baseline core packs are
present. `runner/internal/hostscan/hostscan_security_test.go` asserts that
listeners on declared ports suggest no pack when nothing identifies the service,
and `hostscan_test.go` covers ports corroborating a process match.
