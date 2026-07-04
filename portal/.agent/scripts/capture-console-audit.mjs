#!/usr/bin/env node
// Console screenshot audit — walks EVERY authenticated console page (plus the
// signed-out auth pages) on the :4010 compose stack and writes full-page
// desktop + mobile PNGs for the doctrine grading pass (console-ux.md).
//
// Login is passwordless: submits the seeded demo email on /sign_in, then pulls
// the magic-link URL out of the dev mailbox (/dev/mailbox/json — enabled by
// EMISAR_DEV_ROUTES on the stack) and opens it in the SAME browser (the link
// is nonce-cookie-bound to the requesting browser).
//
//   cd portal/.agent/scripts && npm install && node capture-console-audit.mjs
//
// Env overrides: BASE_URL, EMAIL, ACCOUNT_SLUG, CHROME, OUT_DIR.

import puppeteer from "puppeteer-core";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const BASE = process.env.BASE_URL ?? "http://localhost:4010";
const EMAIL = process.env.EMAIL ?? "demo@emisar.dev";
const SLUG = process.env.ACCOUNT_SLUG ?? "demo";
const CHROME =
  process.env.CHROME ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = process.env.OUT_DIR
  ? resolve(process.env.OUT_DIR)
  : resolve(import.meta.dirname, "../design/screenshots");
mkdirSync(OUT, { recursive: true });

// DESKTOP_WIDTH overrides the desktop viewport — useful for checking whether a
// page's content width caps correctly on a wide monitor (a `:table` 7xl cap only
// shows above ~1536px; below it the content already fits the column).
const DESKTOP = {
  width: Number(process.env.DESKTOP_WIDTH) || 1440,
  height: 900,
  deviceScaleFactor: 1,
};
const MOBILE = { width: 390, height: 844, deviceScaleFactor: 1 };

// Signed-out pages (shot before login).
const AUTH_PAGES = {
  "auth-sign-in": "/sign_in",
  "auth-sign-up": "/sign_up",
  "auth-magic-link": "/sign_in/magic",
};

// Static console routes under /app/:slug.
const CONSOLE_PAGES = {
  dashboard: "",
  runners: "/runners",
  "runner-install": "/runners/install",
  runs: "/runs",
  approvals: "/approvals",
  runbooks: "/runbooks",
  "runbook-new": "/runbooks/new",
  policies: "/policies",
  packs: "/packs",
  audit: "/audit",
  "auth-keys": "/settings/runners/auth-keys",
  agents: "/settings/agents",
  team: "/settings/team",
  "team-invite": "/settings/team/invite",
  sso: "/settings/sso",
  "sso-new": "/settings/sso/new",
  billing: "/settings/billing",
  profile: "/settings/profile",
};

const manifest = [];

async function settle(ms = 1800) {
  await new Promise((r) => setTimeout(r, ms));
}

async function shoot(page, name, note = "") {
  const files = [];
  for (const [vp, label] of [
    [DESKTOP, "desktop"],
    [MOBILE, "mobile"],
  ]) {
    await page.setViewport(vp);
    await settle(900);
    const file = `${name}-${label}.png`;
    await page.screenshot({ path: join(OUT, file), fullPage: true });
    files.push(file);
  }
  await page.setViewport(DESKTOP);
  manifest.push({ name, url: page.url().replace(BASE, ""), files, note });
  console.log(`  ✓ ${name}`);
}

async function gotoAndShoot(page, name, url, note = "") {
  try {
    await page.goto(url, { waitUntil: "networkidle2", timeout: 30000 });
    await settle();
    await shoot(page, name, note);
    return true;
  } catch (err) {
    console.log(`  ✗ ${name} — ${err.message}`);
    manifest.push({ name, url: url.replace(BASE, ""), files: [], note: `FAILED: ${err.message}` });
    return false;
  }
}

// First href on the page whose value matches the `pattern` REGEX (string
// source), skipping hrefs containing `not`. Regex, not substring — a bare
// "/run" contains-match once grabbed the sidebar "/runners" link and shot the
// wrong page.
async function findHref(page, pattern, not = null) {
  return page.evaluate(
    (pattern, not) => {
      const re = new RegExp(pattern);
      const anchors = Array.from(document.querySelectorAll("a[href]"));
      const hit = anchors.find(
        (a) =>
          re.test(a.getAttribute("href")) &&
          (!not || !a.getAttribute("href").includes(not)),
      );
      return hit ? hit.getAttribute("href") : null;
    },
    pattern,
    not,
  );
}

async function mailboxMessages() {
  const res = await fetch(`${BASE}/dev/mailbox/json`);
  if (!res.ok) throw new Error(`mailbox fetch failed: ${res.status}`);
  const body = await res.json();
  return body.data ?? body;
}

// Mailbox messages carry no `id` — key on sent_at+subject for the seen-set.
const mailId = (m) => `${m.sent_at}|${m.subject}`;

// The magic-link URL from the newest mail to EMAIL that isn't in `seenIds`.
async function pollMagicLink(seenIds) {
  for (let i = 0; i < 20; i++) {
    const messages = await mailboxMessages();
    const fresh = messages.find(
      (m) =>
        !seenIds.has(mailId(m)) &&
        JSON.stringify(m.to ?? "").includes(EMAIL) &&
        /sign_in\/magic\//.test(m.text_body ?? ""),
    );
    if (fresh) {
      const match = (fresh.text_body ?? "").match(/https?:\/\/[^\s"]*\/sign_in\/magic\/[^\s")]+/);
      if (match) return match[0].replace(/^https?:\/\/[^/]+/, BASE);
    }
    await settle(500);
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
  await page.setViewport(DESKTOP);

  console.log("auth pages (signed out):");
  for (const [name, path] of Object.entries(AUTH_PAGES)) {
    await gotoAndShoot(page, name, `${BASE}${path}`);
  }

  console.log("login via magic link:");
  const seenIds = new Set((await mailboxMessages()).map(mailId));
  await page.goto(`${BASE}/sign_in`, { waitUntil: "networkidle2" });
  await page.type('input[type="email"]', EMAIL);
  await Promise.all([
    page.waitForNavigation({ waitUntil: "networkidle2" }).catch(() => {}),
    page.keyboard.press("Enter"),
  ]);
  const magicLink = await pollMagicLink(seenIds);
  await page.goto(magicLink, { waitUntil: "networkidle2" });
  await page
    .waitForFunction(() => location.pathname.startsWith("/app/"), { timeout: 20000 })
    .catch(() => {});
  if (!page.url().includes("/app/")) {
    throw new Error(`login failed — landed on ${page.url()}`);
  }
  console.log(`  ✓ signed in (${page.url()})`);

  console.log("console pages:");
  for (const [name, path] of Object.entries(CONSOLE_PAGES)) {
    await gotoAndShoot(page, name, `${BASE}/app/${SLUG}${path}`);
  }

  console.log("detail pages (ids harvested from the lists):");
  const details = [
    { list: "/runners", pattern: `/app/${SLUG}/runners/`, not: "/install", name: "runner-detail" },
    { list: "/runs", pattern: `/app/${SLUG}/runs/`, not: "/new/", name: "run-detail" },
    { list: "/approvals", pattern: `/app/${SLUG}/approvals/`, not: null, name: "approval-detail" },
    { list: "/runbooks", pattern: "/runbooks/[^/]+/edit$", not: null, name: "runbook-edit" },
    { list: "/runbooks", pattern: "/runbooks/[^/]+/run$", not: null, name: "runbook-run" },
    { list: "/settings/sso", pattern: `/app/${SLUG}/settings/sso/`, not: "/new", name: "sso-detail" },
  ];

  for (const d of details) {
    await page.goto(`${BASE}/app/${SLUG}${d.list}`, { waitUntil: "networkidle2" });
    await settle();
    const href = await findHref(page, d.pattern, d.not);
    if (href) {
      await gotoAndShoot(page, d.name, `${BASE}${href}`);
    } else {
      console.log(`  – ${d.name} skipped (no row on ${d.list})`);
      manifest.push({ name: d.name, url: null, files: [], note: `skipped — no row on ${d.list}` });
    }
  }

  // run-new hangs off a runner detail's per-action Run link.
  await page.goto(`${BASE}/app/${SLUG}/runners`, { waitUntil: "networkidle2" });
  await settle();
  const runnerHref = await findHref(page, `/app/${SLUG}/runners/`, "/install");
  if (runnerHref) {
    await page.goto(`${BASE}${runnerHref}`, { waitUntil: "networkidle2" });
    await settle();
    const runNewHref = await findHref(page, "/runs/new/");
    if (runNewHref) {
      await gotoAndShoot(page, "run-new", `${BASE}${runNewHref}`);
    } else {
      manifest.push({ name: "run-new", url: null, files: [], note: "skipped — runner has no Run link" });
    }
  }

  // audit-detail navigates via LiveTable row_click (no anchor) — click row 1.
  await page.goto(`${BASE}/app/${SLUG}/audit`, { waitUntil: "networkidle2" });
  await settle();
  try {
    await page.click("tbody tr");
    await page.waitForFunction(() => /\/audit\/[0-9a-f-]{20,}/.test(location.pathname), {
      timeout: 10000,
    });
    await settle();
    await shoot(page, "audit-detail");
  } catch {
    console.log("  – audit-detail skipped (no clickable row)");
    manifest.push({ name: "audit-detail", url: null, files: [], note: "skipped — no audit rows" });
  }

  writeFileSync(join(OUT, "manifest.json"), JSON.stringify(manifest, null, 2));
  console.log(`\nWrote ${manifest.filter((m) => m.files.length).length} pages to ${OUT}`);
} finally {
  await browser.close();
}
