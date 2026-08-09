# Redaction completeness follows a closed key space

## Rule

A secret-bearing read may be tiered on the strength of its redaction **only when
the software defines a closed, vendor-owned key space**. Then every place a
secret can appear is enumerable, the pack's `output.redact[]` can cover all of
them, and the action is `medium` — it auto-runs under the shipped default.

When the content is **operator-authored free-form text**, the key space is open:
the customer invents the directive names, so no finite rule set covers it. Those
stay `high`. Redaction there is a backstop, and the action's description says so.

**Generic log readers are never above `medium`.** Logs and config are the
front-line diagnostic surface; making them approval-gated breaks the thing agents
are for. Their content is arbitrary, so redaction is explicitly best-effort — that
is an accepted, documented exposure, not an oversight to be "fixed" by re-tiering.
(Founder decision, 2026-08-08.)

## Why

Redaction is pattern-bound. The question is never "is the matcher good?" but "is
the set of things it must match finite and known?"

- `redis.config_get` reads Redis's own config keys. Redis defines them; the
  secret-bearing ones are `requirepass`, `masterauth`, `masteruser`. That list is
  complete and it only changes when Redis ships a new key — a release we track.
- `nginx.config_dump` runs `nginx -T`, which prints main plus every include. A
  credential can ride in `proxy_set_header`, inside a `proxy_pass` URL, in a
  `map`, a `return`, or a `set $anything`. The operator chose those names. No
  enumeration exists.

Same "config dump" shape, opposite guarantees.

## ✅ Good

```yaml
# redis.config_get — closed key space, enumerable secrets, medium
risk: medium
output:
  redact:
    - name: redis-auth-directives
      type: regex
      pattern: '(?im)^(requirepass|masterauth|masteruser)\s+\S+'
      replacement: '\1 [REDACTED]'
```

## ❌ Bad

```yaml
# nginx.config_dump — operator-authored text; this rule set is a guess, not cover
risk: medium          # ← wrong: completeness was assumed, not established
output:
  redact:
    - name: authorization-header
      pattern: 'proxy_set_header\s+Authorization[^;]*'
```

## How to apply it

Before lowering a secret-bearing read from `high`, answer in the action's
description: *who owns the key space?* If the vendor owns it, cite the enumerated
secret keys and the version they were read from. If the operator owns it, the
action stays `high` — say why in `side_effects` rather than adding rules that
imply a guarantee.

Sweep: any `risk: medium` read whose output is a config/environment dump, and any
`risk: high` read over a vendor-defined key space that could be enumerated instead.

## How it's enforced

Review, plus the honest-risk rule in `packs/AGENTS.md`. Not mechanically
checkable — whether a key space is closed is a fact about the upstream software,
not about the YAML.
