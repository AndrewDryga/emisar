# Screenshot tooling

Three scripts against the seeded `:4010` compose stack:

- `capture-docs-screenshots.mjs` — regenerates the cropped console screenshots
  embedded in the `/docs` pages (see below).
- `capture-console-audit.mjs` — walks every console page and writes full-page
  desktop + mobile PNGs for a doctrine grading pass.
- `shot.mjs` — one page, full-page PNG + an element crop; the before/after
  proof loop for a user-requested UI fix
  (`../rules/design-ui-fix-screenshot-proof.md`):

  ```sh
  node shot.mjs /app/demo/runners --label before --select '#runners'
  # fix → rebuild the stack → same command with --label after
  ```

  Anchors: `--select CSS`, `--heading "exact text"` (+ `--climb section`), or
  `--class-contains a,b`; `--width 390` for mobile. Output lands in
  `test-results/ui-fix/` (repo root, gitignored).

## Docs screenshots

`capture-docs-screenshots.mjs` regenerates the cropped console screenshots
embedded in the `/docs` pages under
`portal/apps/emisar_web/priv/static/images/`. It logs into the seeded compose
stack, captures each relevant product surface, pads the crop, and rewrites the
shipped WebP.

## Prereqs (macOS)

- **Compose stack** running from the repository root: `docker compose up -d`
  (serves the seeded portal on `:4010`).
- **Google Chrome** installed, and **ImageMagick** on `PATH`
  (`brew install imagemagick`).

## With a coop box (serve in the box, capture on the host)

Run portal **inside the box** so its live code is what you shoot, publish the port,
and capture from the **host** (macOS Chrome + ImageMagick, the prereqs above):

```sh
# 1. in the box (coop shell), serve portal — PGHOST=db is baked, dev binds 0.0.0.0:4000:
cd portal && mix ecto.setup && mix phx.server        # ecto.setup seeds demo@emisar.dev
#    coop prints:  serving box :4000 at http://localhost:<PORT>   (a stable, distinct host
#    port — never collides with your host's own :4000 dev or :4010 compose stack)

# 2. on the host, shoot against that published port:
cd portal/.agent/scripts
BASE_URL=http://localhost:<PORT> node shot.mjs /pricing --label after --heading "Pricing"
```

`test-results/` is repo-mounted, so the PNGs land in your working tree either way.
`resolve-chrome.mjs` finds the browser automatically (host Chrome, or `$CHROME`).

> **Capturing from *inside* the box isn't wired up yet.** The scripts are
> box-portable (browser resolver + container-safe Chrome flags), but Playwright's
> Chromium currently SIGTRAPs in a coop box's mount composition (it launches fine in
> a bare container with the same hardening) — tracked in coop's queue as
> `box-chromium-sigtraps`. Until that lands, capture host-side as above.

## Run

```sh
cd portal/.agent/scripts
npm ci                   # locked, reproducible install (.npmrc keeps scripts off)
npm run capture          # or: node capture-docs-screenshots.mjs
```

Review the changed WebPs under `apps/emisar_web/priv/static/images/`.

## Add a screenshot

1. Add the console navigation and crop target to the script's capture section.
2. Embed it in the docs page:
   `<img src="/images/screenshots/<webp-name>.webp" alt="…" loading="lazy" class="w-full" />`.
3. Re-run.

Env overrides: `BASE_URL`, `EMAIL`, `CHROME`.
