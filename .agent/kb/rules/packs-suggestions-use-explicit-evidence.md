# Packs: suggestions use explicit evidence

## Rule

Build pack suggestions only from the pack's explicit `detect` declaration.
Never infer detection binaries from `requires.binaries`. A pack without authored
detection evidence is omitted from host suggestions.

## Why

Requirements answer whether an installed action can execute, not whether its
target exists on this host. Generic helpers such as `timeout` and `base64`, and
configuration-dependent clients such as `git`, otherwise turn ordinary base
images into confident but false Nomad, OIDC, and repository recommendations.
Maintaining exception lists only moves the next false positive into production.

## Good

```yaml
requires:
  binaries: [nomad, jq, timeout]
detect:
  processes: [nomad]
  ports: [4646]
```

Only the authored Nomad evidence enters `suggest.json`; helper dependencies do
not.

## Bad

```text
detect.binaries = requires.binaries - known_generic_helpers
```

The exception list incorrectly treats every unknown dependency as service
identity.

## Sweep

Search catalog builders and local-catalog suggestion paths for fallbacks from
`requires.binaries` into `detect.binaries`. Review packs without a `detect`
block as intentionally manual rather than silently deriving a signal.

## Enforcement

`runner/internal/catalog/catalog_test.go` builds a pack requiring `git`,
`timeout`, `base64`, and a service-looking binary without a `detect` block and
asserts that none appears in its detection metadata or suggestion index.
