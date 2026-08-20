# Public docs state required actions, not private implementation

## Rule

Public documentation tells the reader what they must do, allow, choose, or rely
on through a stable customer-facing contract.

- Name the public domain, port, path, command, or product behavior the customer
  uses.
- Omit the backing provider, storage service, internal routing, account, and
  deployment topology behind that contract.
- Omit unsolicited statements about actions the reader does not need to take.
- Name an optional requirement only when the reader may choose the feature or
  fallback that requires it, and label it optional at the point of use.

This is not a ban on limits, warnings, or security properties. State an absence
when it changes a decision on the page that owns that contract. For example,
outbound-only runner connectivity belongs in the security model. It does not
belong as an extra "you do not need" sentence in installation prerequisites.

## Why

Backing infrastructure can change without changing the customer contract.
Publishing it creates stale documentation and makes an internal vendor or
topology look like a customer dependency. Unsolicited non-actions add work to a
procedure by making the reader evaluate steps they were never asked to perform.

## Good

```text
Allow outbound HTTPS to emisar.dev:443 and registry.emisar.dev:443.
```

```text
To enable the GitHub release fallback, also allow api.github.com:443,
github.com:443, and release-assets.githubusercontent.com:443.
```

## Bad

```text
The public endpoint is backed by our storage vendor. You do not need access to
that storage service or an inbound port.
```

The backing store is private implementation, and the second sentence describes
work the reader was not instructed to do.

## Sweep

When changing public setup, prerequisites, networking, or integration copy,
search nearby public surfaces for backing-provider names, internal topology,
and phrases such as `you do not need`, `needs no`, and `nothing to configure`.
Keep only statements that change the reader's action or a decision owned by that
page.

## Enforcement

Review enforces this judgment rule. Rendered-page tests should pin known
customer-facing domains and reject any backing-provider detail that previously
escaped onto that surface.
