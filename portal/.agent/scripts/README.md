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
