# Screenshot tooling

Three scripts against the active `dev/run serve` workspace:

- `capture-docs-screenshots.mjs` — regenerates the cropped console screenshots
  embedded in the `/docs` pages (see below).
- `capture-console-audit.mjs` — walks every console page and writes full-page
  desktop + mobile PNGs for a doctrine grading pass.
- `shot.mjs` — one page, full-page PNG + an element crop; the before/after
  proof loop for a user-requested UI fix
  (`../rules/design-ui-fix-screenshot-proof.md`):

  ```sh
  dev/run shot /app/demo/runners --label before --select '#runners'
  # fix → Phoenix reloads → same command with --label after
  ```

  Anchors: `--shot NAME` for a stable `data-shot` marker, `--select CSS`,
  `--heading "exact text"` (+ `--climb section`), or `--class-contains a,b`;
  `--width 390` for mobile. Pass the owning task's `--out` directory.

## Docs screenshots

`capture-docs-screenshots.mjs` regenerates the cropped console screenshots
embedded in the `/docs` pages under
`portal/apps/emisar_web/priv/static/images/`. It logs into the active seeded
workspace, captures each relevant product surface, pads the crop, and rewrites the
shipped WebP.

## Prerequisites

- `dev/run setup`, an explicit `dev/run seed`, and `dev/run serve`.
- Google Chrome or the pinned headless shell installed by setup. The Coop image
  includes ImageMagick and browser libraries.

## Host and Coop

The same command works on the host and inside an interactive Coop box:

```sh
dev/run serve
dev/run shot /pricing --label after --heading Pricing --out .agent/screenshots/pricing
```

Coop mirrors the public workspace URL back into the box, so LiveView and OIDC
use the same URL as the host browser. `dev/run shot` keeps a browser process
alive between captures; `dev/run browser stop` releases it.

## Run

```sh
dev/run capture docs
```

Use `dev/run capture console` for the full signed-out and authenticated console
audit. Both commands discover the active workspace URL and reuse its browser.
On a macOS host, docs capture additionally requires ImageMagick; the Coop image
already includes it.

Review the changed WebPs under `apps/emisar_web/priv/static/images/`.

## Add a screenshot

1. Add the console navigation and crop target to the script's capture section.
2. Embed it in the docs page:
   `<img src="/images/screenshots/<webp-name>.webp" alt="…" loading="lazy" class="w-full" />`.
3. Re-run.

All npm installs use `--ignore-scripts`; dependencies are exact-pinned. Env
overrides: `BASE_URL`, `EMAIL`, `CHROME`, `BROWSER_STATE`, `PROFILE_DIR`.
