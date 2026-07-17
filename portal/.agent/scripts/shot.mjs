#!/usr/bin/env node
// Before/after proof shots for a single UI fix (design-ui-fix-screenshot-proof
// rule): one page on the seeded :4010 compose stack → a full-page PNG plus a
// crop of the element under fix.
//
//   # task-scoped work — pass the task's own screenshots/ folder:
//   node shot.mjs /app/demo/runners --label before --select '#runners' \
//     --out .agent/tasks/10_in_progress/<id>/screenshots
//   # one-off (no task) — a dated, named folder under .agent/screenshots/:
//   node shot.mjs /pricing --label after --heading "Pricing" --climb section \
//     --out .agent/screenshots/2026-07-16-pricing-headline
//
// Pass --out so shots land with the work that owns them (both paths are
// git-ignored); a forgotten --out falls back to .agent/screenshots/scratch.
// Anchors (same logic as capture-docs-screenshots.mjs): --select CSS,
// --heading "exact text" (tightest enclosing element), or --class-contains a,b
// (Tailwind arbitrary classes don't select via CSS); --climb SEL walks up to a
// container. Writes <out>/<label>-full.png and, with an anchor,
// <out>/<label>-crop.png. Console paths (/app/…) log in as the seeded demo
// user via the dev-mailbox magic link, on a persistent Chrome profile so
// repeat runs skip login. Env overrides: BASE_URL, EMAIL, CHROME, PROFILE_DIR.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { resolveChrome, containerChromeArgs } from "./resolve-chrome.mjs";

const BASE = process.env.BASE_URL ?? "http://localhost:4010";
const EMAIL = process.env.EMAIL ?? "demo@emisar.dev";
const CHROME = resolveChrome();
const PROFILE = process.env.PROFILE_DIR ?? "/tmp/emisar-uifix-profile";

const argv = process.argv.slice(2);
const flags = {};
let path = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) flags[argv[i].slice(2)] = argv[++i];
  else path = argv[i];
}
if (!path || !flags.label) {
  console.error(
    'usage: node shot.mjs <path> --label <before|after> [--select CSS] [--heading "TEXT"] [--class-contains a,b] [--climb SEL] [--click SEL] [--width 1440] [--settle 1200] [--out DIR]',
  );
  process.exit(1);
}
const OUT = flags.out
  ? resolve(flags.out)
  : resolve(import.meta.dirname, "../../../.agent/screenshots/scratch");
mkdirSync(OUT, { recursive: true });
const WIDTH = Number(flags.width) || 1440;
const SETTLE = Number(flags.settle) || 1200;
const anchor =
  flags.select || flags.heading || flags["class-contains"]
    ? {
        selector: flags.select ?? null,
        heading: flags.heading ?? null,
        classContains: flags["class-contains"]?.split(",") ?? null,
        climb: flags.climb ?? null,
      }
    : null;

const settle = (ms = SETTLE) => new Promise((r) => setTimeout(r, ms));
const mailId = (m) => `${m.sent_at}|${m.subject}`;
const mailbox = async () =>
  (await (await fetch(`${BASE}/dev/mailbox/json`)).json()).data ?? [];
const target = path.startsWith("http") ? path : `${BASE}${path}`;

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  userDataDir: PROFILE,
  args: [...containerChromeArgs, "--force-prefers-reduced-motion"],
});

try {
  const page = await browser.newPage();
  await page.setViewport({ width: WIDTH, height: 900, deviceScaleFactor: 1 });

  // CDP's Page.navigate rejects bracketed query params ([]); set location
  // in-page (Chrome parses it fine) for URLs that carry filter params.
  const go = async (url) => {
    if (url.includes("[")) {
      if (page.url() === "about:blank")
        await page.goto(BASE, { waitUntil: "domcontentloaded" });
      await Promise.all([
        page.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => {}),
        page.evaluate((u) => {
          window.location.href = u;
        }, url),
      ]);
    } else {
      await page.goto(url, { waitUntil: "domcontentloaded" });
    }
    await settle();
  };

  await go(target);

  // Console paths bounce to /sign_in when the profile isn't authed — log in
  // via the dev-mailbox magic link, then return to the target.
  if (new URL(page.url()).pathname.startsWith("/sign_in")) {
    const seen = new Set((await mailbox()).map(mailId));
    await page.goto(`${BASE}/sign_in`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector('input[type="email"]');
    await page.type('input[type="email"]', EMAIL);
    await Promise.all([
      page.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => {}),
      page.keyboard.press("Enter"),
    ]);
    let link;
    for (let i = 0; i < 40 && !link; i++) {
      const fresh = (await mailbox()).find(
        (m) =>
          !seen.has(mailId(m)) &&
          JSON.stringify(m.to ?? "").includes(EMAIL) &&
          /sign_in\/magic\//.test(m.text_body ?? ""),
      );
      if (fresh)
        link = (fresh.text_body.match(
          /https?:\/\/[^\s"]*\/sign_in\/magic\/[^\s")]+/,
        ) || [])[0]?.replace(/^https?:\/\/[^/]+/, BASE);
      if (!link) await settle(500);
    }
    if (!link) throw new Error("no magic-link email showed up in /dev/mailbox");
    await page.goto(link, { waitUntil: "domcontentloaded" });
    // Login is done once we leave /sign_in — the return-to isn't always /app/
    // (an /oauth/authorize consent URL bounces back to itself).
    await page.waitForFunction(() => !location.pathname.startsWith("/sign_in"));
    await go(target);
  }

  // Reveal a click-gated state (a tab, a disclosure, a menu) before capturing.
  if (flags.click) {
    await page.waitForSelector(flags.click);
    await page.click(flags.click);
    await settle();
  }

  const full = join(OUT, `${flags.label}-full.png`);
  await page.screenshot({ path: full, fullPage: true });
  console.log(`✓ ${full}`);

  if (anchor) {
    const ok = await page.evaluate((t) => {
      // Only visible nodes — text matches otherwise land on the hidden mobile
      // drawer's copy of the same label and puppeteer dies on the 0-size box.
      const visible = (n) => n.checkVisibility();
      let el = t.selector ? document.querySelector(t.selector) : null;
      if (!el && t.classContains) {
        el =
          [...document.querySelectorAll("div,section")].find(
            (d) =>
              visible(d) && t.classContains.every((c) => d.className.includes(c)),
          ) || null;
      }
      if (!el && t.heading) {
        el =
          [...document.querySelectorAll("h1,h2,h3,h4,div,span,p")]
            .filter((n) => visible(n) && n.textContent.trim() === t.heading)
            .sort(
              (a, b) =>
                a.querySelectorAll("*").length - b.querySelectorAll("*").length,
            )[0] || null;
      }
      if (!el) return false;
      if (t.climb) el = el.closest(t.climb) || el;
      if (!visible(el)) return false;
      el.setAttribute("data-shot", "1");
      return true;
    }, anchor);
    if (!ok) throw new Error(`anchor not found (or not visible) on ${page.url()}`);

    // The crop is what gets reviewed closely — re-shoot it at 2x for crisp
    // detail. The full page stays 1x: a tall page at 2x trips Chrome's ~16k
    // capture-height cap.
    await page.setViewport({ width: WIDTH, height: 900, deviceScaleFactor: 2 });
    await settle(600);
    const handle = await page.$('[data-shot="1"]');
    const box = await handle.boundingBox();
    const crop = join(OUT, `${flags.label}-crop.png`);
    await handle.screenshot({ path: crop });
    console.log(`✓ ${crop}  ${Math.round(box.width)}x${Math.round(box.height)}`);
  }
} finally {
  await browser.close();
}
