# Runner: host readiness stays separate from descriptors

## Rule

Keep the complete runner action descriptor set intact for exact trusted-manifest
verification. Report mutable host readiness as separate evidence that can only
remove executable targets.

## Why

Omitting an action because its executable or another prerequisite is absent
makes a host configuration problem indistinguishable from descriptor drift and
can disable every sibling action in a mixed-capability pack. Folding readiness
into trusted manifest identity also lets mutable host state weaken the integrity
contract.

## Good

- Advertise every admitted action descriptor.
- Compare the complete descriptor set to the exact trusted manifest.
- Filter an otherwise compatible action only when separate host evidence is
  definitively unavailable.
- Preserve unknown readiness from older runners as rolling-compatible.

## Bad

- Drop a descriptor because a binary is missing.
- Mark the whole pack unavailable because one action cannot start.
- Treat a positive host check as a substitute for pack trust or functional
  verification.

## Sweep

Search runner-state builders, portal catalog projections, and dispatch gates for
code that filters descriptors or derives executability without preserving exact
manifest comparison.
