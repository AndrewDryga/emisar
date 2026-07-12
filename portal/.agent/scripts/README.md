# Docs screenshots

`capture-docs-screenshots.mjs` regenerates the console screenshots embedded in
the `/docs` pages — `portal/apps/emisar_web/priv/static/images/screenshots/*.webp`
— so they don't go stale when the dashboard UI changes. It logs in headless,
walks the console, and rewrites each WebP.

## Prereqs (macOS)

- **Dev server** running: `cd portal && mix phx.server` (serves `:4000`).
- **Dev seed** applied: `cd portal && mix run apps/emisar/priv/repo/seeds.exs`
  — creates the `demo@emisar.dev` account with realistic runners / packs / runs /
  approvals / audit, so the screenshots aren't empty states.
- **Google Chrome** installed, and **ImageMagick** on `PATH`
  (`brew install imagemagick`).

## Run

```sh
cd portal/.agent/scripts
npm ci                   # locked, reproducible install (.npmrc keeps scripts off)
npm run capture          # or: node capture-docs-screenshots.mjs
```

Review the diff under `priv/static/images/screenshots/` and commit the WebPs.
(Capturing to a scratch dir first to eyeball them: `OUT_DIR=/tmp/shots npm run capture`.)

## Add a screenshot

1. Add an entry to `SHOTS` in the script: `"<webp-name>": "/console/path"`
   (the path is under `/app/:slug`).
2. Embed it in the docs page:
   `<img src="/images/screenshots/<webp-name>.webp" alt="…" loading="lazy" class="w-full" />`.
3. Re-run.

Env overrides: `DEV_URL`, `EMAIL`, `PASSWORD`, `ACCOUNT_SLUG`, `CHROME`, `OUT_DIR`.
