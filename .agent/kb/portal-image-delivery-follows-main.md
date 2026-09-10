---
name: portal-image-delivery-follows-main
description: Every successful main push publishes its exact tested portal image; production planning has no stale-image fallback, and the deployed revision is proven from the image label and /app/REVISION rather than reported by the anonymous health probes.
subsystem: infra
sources: [tools/internal/ci/select.go, .github/workflows/ci.yml, .github/workflows/cd.yml, portal/Dockerfile, portal/apps/emisar_web/lib/emisar_web/controllers/health_controller.ex]
updated: 2026-09-10
---

CD treats `main` as the complete desired portal state, not just the latest
commit's path diff. Every main push runs the portal gates and publishes the exact
tested image; the HCP plan requires that digest and cannot substitute the last
applied image. This preserves undeployed application drift across failed plans.

The product version can remain unchanged across many commits, so the version
alone cannot identify a deployment. `/healthz` and `/readyz` still report only
the product version: the repository is public, and the exact deployed Git SHA
would hand an anonymous caller the precise source tree and lockfile serving
production. The revision is proven from the image instead — CD reads the
`org.opencontainers.image.revision` label of the tested image and requires it
to equal the current `main` commit, the same value the build writes to
`/app/REVISION`, and the deploy is pinned by that image's digest.

## Changelog
- 2026-09-10 — the health probes stopped reporting the revision on 2026-08-29 (public repository); the card now describes the image-label proof CD actually performs
- 2026-07-21 — moved revision metadata to the final runtime layer so revision-only builds retain every reusable builder and release layer
- 2026-07-21 — created after a failed portal plan was followed by an infra-only plan that retained the previous applied image
