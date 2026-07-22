---
name: portal-image-delivery-follows-main
description: Every successful main push publishes its exact tested portal image; production planning has no stale-image fallback, and health reports the embedded source revision.
subsystem: infra
sources: [.github/scripts/select-ci.sh, .github/workflows/ci.yml, .github/workflows/cd.yml, portal/Dockerfile, portal/apps/emisar_web/lib/emisar_web/controllers/health_controller.ex]
updated: 2026-07-21
---

CD treats `main` as the complete desired portal state, not just the latest
commit's path diff. Every main push runs the portal gates and publishes the exact
tested image; the HCP plan requires that digest and cannot substitute the last
applied image. This preserves undeployed application drift across failed plans.

The product version can remain unchanged across many commits. `/healthz` and
`/readyz` therefore report the Git revision embedded in the image, and
post-apply checks compare it with the reviewed main commit.

## Changelog
- 2026-07-21 — moved revision metadata to the final runtime layer so revision-only builds retain every reusable builder and release layer
- 2026-07-21 — created after a failed portal plan was followed by an infra-only plan that retained the previous applied image
