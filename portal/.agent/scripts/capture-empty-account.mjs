#!/usr/bin/env node
// Empty-account state capture: signs UP a fresh user (real flow — sign-up →
// magic code → onboarding → create workspace), then walks every console page
// on the brand-new EMPTY account. The zero-state matrix in pixels.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

const BASE = process.env.BASE_URL ?? "http://localhost:4010";
const STAMP = Date.now().toString(36);
const EMAIL = `empty-${STAMP}@emisar.dev`;
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = resolve(
  process.env.OUT_DIR ?? resolve(import.meta.dirname, "../../../test-results/empty-account"),
);
mkdirSync(OUT, { recursive: true });
const settle = (ms = 1400) => new Promise(r => setTimeout(r, ms));
async function mailbox() { const r = await fetch(`${BASE}/dev/mailbox/json`); const b = await r.json(); return b.data ?? b; }
const mailId = m => `${m.sent_at}|${m.subject}`;

const browser = await puppeteer.launch({ executablePath: CHROME, headless: "new", args: ["--no-sandbox", "--force-prefers-reduced-motion"] });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 1100, deviceScaleFactor: 1 });

// Sign up
const seen = new Set((await mailbox()).map(mailId));
await page.goto(`${BASE}/sign_up`, { waitUntil: "networkidle2" });
const texts = await page.$$('input[type="text"]');
await texts[0].type("Empty Tester");
await page.type('input[type="email"]', EMAIL);
if (texts[1]) await texts[1].type(`Empty Co ${STAMP}`);
await settle(400);
await Promise.all([
  page.waitForNavigation({ waitUntil: "networkidle2" }).catch(() => {}),
  page.click('form button.w-full'),
]);
await settle(1200);
await page.screenshot({ path: join(OUT, "signup-after-submit.png"), fullPage: true });
// Sign-up sends a CONFIRMATION link (/confirm/<token>), not a sign-in magic link.
let link = null;
for (let i = 0; i < 24 && !link; i++) {
  const fresh = (await mailbox()).find(m => !seen.has(mailId(m)) && JSON.stringify(m.to ?? "").includes(EMAIL) && /\/(confirm|sign_in\/magic)\//.test(m.text_body ?? ""));
  if (fresh) link = (fresh.text_body ?? "").match(/https?:\/\/[^\s"]*\/(confirm|sign_in\/magic)\/[^\s")]+/)?.[0]?.replace(/^https?:\/\/[^/]+/, BASE);
  if (!link) await settle(500);
}
if (!link) throw new Error("no confirmation link for sign-up");
await page.goto(link, { waitUntil: "networkidle2" });
await settle();
await page.screenshot({ path: join(OUT, "post-confirm-desktop.png"), fullPage: true });

// If a magic-code / continue step renders, follow the primary button.
const cont = await page.$("form button.w-full");
if (cont && !page.url().includes("/app/")) {
  await Promise.all([page.waitForNavigation({ waitUntil: "networkidle2" }).catch(() => {}), cont.click()]);
  await settle();
}
await page.waitForFunction(() => location.pathname.startsWith("/app/"), { timeout: 20000 }).catch(() => {});
const slug = page.url().match(/\/app\/([^/?#]+)/)?.[1];
if (!slug) throw new Error(`onboarding did not land in an account: ${page.url()}`);
console.log(`account: ${slug}`);

const PAGES = {
  dashboard: "", runners: "/runners", "runner-keys": "/runners/keys", runs: "/runs",
  approvals: "/approvals", audit: "/audit", packs: "/packs", policies: "/policies",
  runbooks: "/runbooks", agents: "/settings/agents", team: "/settings/team",
  sso: "/settings/sso", billing: "/settings/billing", profile: "/settings/profile",
};
for (const [name, path] of Object.entries(PAGES)) {
  try {
    await page.goto(`${BASE}/app/${slug}${path}`, { waitUntil: "networkidle2", timeout: 30000 });
    await settle();
    await page.screenshot({ path: join(OUT, `${name}-desktop.png`), fullPage: true });
    console.log(`  ✓ ${name}`);
  } catch (e) { console.log(`  ✗ ${name} — ${e.message}`); }
}
await browser.close();
console.log("done");
