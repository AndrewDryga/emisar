#!/usr/bin/env node
// Regenerate the /docs console screenshots from a seeded dev account, so they
// don't go stale when the dashboard UI changes. Logs in headless, walks the
// console, and rewrites portal/apps/emisar_web/priv/static/images/screenshots/*.webp
// (the images embedded in the /docs pages).
//
// Login is passwordless (auth is magic-link only): submits the seeded demo
// email on /sign_in, then pulls the magic-link URL out of the dev mailbox
// (/dev/mailbox/json) and opens it in the SAME browser — the link is
// nonce-cookie-bound to the requesting browser.
//
// Prereqs (macOS): the dev server on :4000 (or DEV_URL=http://localhost:4010
// for the compose stack), the dev seed applied so demo@emisar.dev exists,
// Google Chrome, and ImageMagick (`magick`). See README.
//
//   cd portal/.agent/scripts && npm install && npm run capture
//
// Env overrides: DEV_URL, EMAIL, ACCOUNT_SLUG, CHROME, OUT_DIR.

import puppeteer from "puppeteer-core";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const DEV_URL = process.env.DEV_URL ?? "http://localhost:4000";
const EMAIL = process.env.EMAIL ?? "demo@emisar.dev";
const SLUG = process.env.ACCOUNT_SLUG ?? "demo";
const CHROME =
  process.env.CHROME ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

// output WebP name  →  console path under /app/:slug (and the docs page it sits on).
const SHOTS = {
  "connect-llm-agents": "/settings/agents", // docs/connect-an-llm
  "policy-editor": "/policies", //            docs/policies-and-approvals
  "runner-fleet": "/runners", //              docs/runners
  "audit-view": "/audit", //                  docs/audit-and-siem
  "team-page": "/settings/team", //           docs/teams-and-access
  runbooks: "/runbooks", //                   docs/runbooks
};

const OUT = process.env.OUT_DIR
  ? resolve(process.env.OUT_DIR)
  : resolve(
      import.meta.dirname,
      "../../apps/emisar_web/priv/static/images/screenshots",
    );
mkdirSync(OUT, { recursive: true });

const tmp = mkdtempSync(join(tmpdir(), "emisar-shots-"));

async function mailboxMessages() {
  const res = await fetch(`${DEV_URL}/dev/mailbox/json`);
  if (!res.ok) throw new Error(`mailbox fetch failed: ${res.status}`);
  const body = await res.json();
  return body.data ?? body;
}

// The magic-link URL from the newest mail to EMAIL that isn't in `seenIds`.
async function pollMagicLink(seenIds) {
  for (let i = 0; i < 20; i++) {
    const messages = await mailboxMessages();
    const fresh = messages.find(
      (m) =>
        !seenIds.has(m.id) &&
        JSON.stringify(m.to ?? "").includes(EMAIL) &&
        /sign_in\/magic\//.test(m.text_body ?? ""),
    );
    if (fresh) {
      const match = (fresh.text_body ?? "").match(
        /https?:\/\/[^\s"]*\/sign_in\/magic\/[^\s")]+/,
      );
      if (match) return match[0].replace(/^https?:\/\/[^/]+/, DEV_URL);
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("no magic-link email showed up in /dev/mailbox");
}

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  args: ["--no-sandbox", "--force-prefers-reduced-motion"],
});

try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 1024, deviceScaleFactor: 2 });

  const seenIds = new Set((await mailboxMessages()).map((m) => m.id));
  await page.goto(`${DEV_URL}/sign_in`, { waitUntil: "networkidle2" });
  await page.type('input[type="email"]', EMAIL);
  await Promise.all([
    page.waitForNavigation({ waitUntil: "networkidle2" }).catch(() => {}),
    page.keyboard.press("Enter"),
  ]);
  const magicLink = await pollMagicLink(seenIds);
  await page.goto(magicLink, { waitUntil: "networkidle2" });
  await page
    .waitForFunction(() => location.pathname.startsWith("/app/"), {
      timeout: 20000,
    })
    .catch(() => {});

  if (!page.url().includes(`/app/${SLUG}`)) {
    throw new Error(
      `login failed (landed on ${page.url()}) — is the dev seed applied and the "${SLUG}" account loginable?`,
    );
  }

  for (const [name, path] of Object.entries(SHOTS)) {
    await page.goto(`${DEV_URL}/app/${SLUG}${path}`, {
      waitUntil: "networkidle2",
    });
    await new Promise((r) => setTimeout(r, 2500)); // let LiveView async mounts settle
    const png = join(tmp, `${name}.png`);
    await page.screenshot({ path: png });
    // downscale to 1600w + WebP — crisp at the docs content width, small file.
    execFileSync("magick", [
      png,
      "-resize",
      "1600x",
      "-quality",
      "82",
      join(OUT, `${name}.webp`),
    ]);
    console.log(`  ✓ ${name}.webp  ←  ${path}`);
  }
  console.log(`\nWrote ${Object.keys(SHOTS).length} screenshots to ${OUT}`);
} finally {
  await browser.close();
  rmSync(tmp, { recursive: true, force: true });
}
