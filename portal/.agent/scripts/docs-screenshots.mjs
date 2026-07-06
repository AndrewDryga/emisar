// Regenerate the docs screenshots end-to-end: capture → pad → webp.
// Each is CROPPED to the feature its doc section is about (no sidebar, no page
// chrome), then given an invisible ~20px border in its OWN background colour so
// text never touches the edge. Logs in as demo (enterprise — has SSO + SCIM +
// runbooks + a fleet), captures the relevant element/section, and writes the
// final webp assets under priv/static/images. Needs ImageMagick (`magick`).
// Run it (:4010 up) whenever a screened surface changes: `node _shot-docs.mjs`.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { resolve } from "node:path";
const BASE = "http://localhost:4010", EMAIL = "demo@emisar.dev";
const OUT = "/tmp/docshots";
const STATIC = resolve(import.meta.dirname, "../../apps/emisar_web/priv/static/images");
mkdirSync(OUT, { recursive: true });
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const mailId = (m) => `${m.sent_at}|${m.subject}`;
const mailbox = async () => (await (await fetch(`${BASE}/dev/mailbox/json`)).json()).data ?? [];
// Each crop's canvas colour, sampled from the DOM (not a corner pixel, which
// could land on text) — the padding fills with THIS so it's invisible.
const bgColors = {};
const rgbToHex = (rgb) => {
  const m = (rgb || "").match(/\d+/g);
  return m ? "#" + m.slice(0, 3).map((n) => (+n).toString(16).padStart(2, "0")).join("") : "#09090b";
};

async function crop(page, target, name) {
  // Mark the target (by CSS selector, or by a heading's exact text → its
  // enclosing <section>) with data-shot, then screenshot THAT element — a
  // sibling above it (e.g. a filter form over a results table) is excluded by
  // construction, and puppeteer scrolls/stitches a tall element for us.
  const ok = await page.evaluate((t) => {
    let el = t.selector ? document.querySelector(t.selector) : null;
    if (!el && t.classContains) {
      // Tailwind arbitrary classes (brackets/parens) don't select via CSS —
      // match the element whose className contains ALL the given substrings.
      el =
        [...document.querySelectorAll("div,section")].find((d) =>
          t.classContains.every((c) => d.className.includes(c)),
        ) || null;
    }
    if (!el && t.heading) {
      // Tightest element (fewest descendants) whose text is exactly the heading —
      // handles a heading wrapping nested spans/icons.
      el =
        [...document.querySelectorAll("h1,h2,h3,h4,div,span,p")]
          .filter((n) => n.textContent.trim() === t.heading)
          .sort((a, b) => a.querySelectorAll("*").length - b.querySelectorAll("*").length)[0] || null;
    }
    if (!el) return false;
    if (t.climb) el = el.closest(t.climb) || el;
    el.setAttribute("data-shot", "1");
    return true;
  }, target);
  if (!ok) throw new Error("anchor not found: " + name);
  await settle(150);
  const handle = await page.$('[data-shot="1"]');
  const box = await handle.boundingBox();
  await handle.screenshot({ path: `${OUT}/${name}.png` });
  // The canvas colour behind this crop = the first ancestor with a real bg.
  bgColors[name] = rgbToHex(
    await page.evaluate(() => {
      let el = document.querySelector('[data-shot="1"]');
      while (el) {
        const c = getComputedStyle(el).backgroundColor;
        if (c && c !== "rgba(0, 0, 0, 0)" && c !== "transparent") return c;
        el = el.parentElement;
      }
      return "rgb(9, 9, 11)";
    }),
  );
  await page.evaluate(() => document.querySelector('[data-shot="1"]')?.removeAttribute("data-shot"));
  console.log(`  ✓ ${name}  ${Math.round(box.width)}x${Math.round(box.height)}  bg=${bgColors[name]}`);
}

const b = await puppeteer.launch({ executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: "new", args: ["--no-sandbox", "--force-prefers-reduced-motion"] });
const p = await b.newPage();
await p.setViewport({ width: 1680, height: 2800, deviceScaleFactor: 2 });

// --- login ---
const seen = new Set((await mailbox()).map(mailId));
await p.goto(`${BASE}/sign_in`, { waitUntil: "domcontentloaded" });
await p.waitForSelector('input[type="email"]'); await p.type('input[type="email"]', EMAIL);
await Promise.all([p.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => {}), p.keyboard.press("Enter")]);
let link;
for (let i = 0; i < 40; i++) { const f = (await mailbox()).find((m) => !seen.has(mailId(m)) && JSON.stringify(m.to ?? "").includes(EMAIL) && /sign_in\/magic\//.test(m.text_body ?? "")); if (f) { link = (f.text_body.match(/https?:\/\/[^\s"]*\/sign_in\/magic\/[^\s")]+/) || [])[0].replace(/^https?:\/\/[^/]+/, BASE); break; } await settle(500); }
if (!link) throw new Error("no magic link found in mailbox");
await p.goto(link, { waitUntil: "domcontentloaded" }); await p.waitForFunction(() => location.pathname.startsWith("/app/"));

const go = async (path) => { await p.goto(`${BASE}${path}`, { waitUntil: "domcontentloaded" }); await settle(1100); };
// CDP's Page.navigate rejects bracketed query params ([]); set location in-page
// (Chrome parses it fine) for URLs that carry filter params.
const goRaw = async (path) => {
  await Promise.all([
    p.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => {}),
    p.evaluate((u) => { window.location.href = u; }, `${BASE}${path}`),
  ]);
  await settle(1200);
};

await go("/app/demo/policies");
await crop(p, { heading: "Default policy", climb: "section" }, "policy-editor");

// The natural log leads with auth + runner-lifecycle noise; filter to the Run
// group so the hero shows the audit trail's core — gated action dispatches with
// their outcomes (Succeeded / Failed / Awaiting approval) — capped to a slice.
await goRaw("/app/demo/audit?event_type[]=group:Run");
await crop(p, { selector: "#audit-events" }, "audit-view"); // tall; conversion crops the top slice

await go("/app/demo/runbooks");
await crop(p, { selector: "#runbooks" }, "runbooks");

await go("/app/demo/runners");
await crop(p, { selector: "#runners" }, "runner-fleet");

await go("/app/demo/settings/team");
await crop(p, { selector: "#members", climb: "section" }, "team-page");

await go("/app/demo/settings/sso/new");
await crop(p, { selector: "#provider_form" }, "sso-add-connection");

// SSO connection detail — click through from the Team page's connection link.
await go("/app/demo/settings/team");
await p.evaluate(() => {
  const a = [...document.querySelectorAll('a[href*="/settings/sso/"]')].find((x) => /\/settings\/sso\/[0-9a-f-]{8,}/.test(x.getAttribute("href")));
  if (a) a.click();
});
await settle(1400);
await crop(p, { heading: "Directory sync (SCIM)", climb: "section" }, "sso-directory-sync");

// LLM agents — the "Connect an agent" client picker (the /docs/connect-an-llm
// hero): pick a client and it mints a pre-filled key + setup. Select one so the
// per-client config shows beside the picker, not an empty prompt.
await go("/app/demo/agents/connect");
await p.evaluate(() => {
  const tab = [...document.querySelectorAll("button, a, [phx-click]")].find(
    (b) => b.textContent.trim() === "Claude.ai",
  );
  if (tab) tab.click();
});
await settle(900);
await crop(p, { classContains: ["grid-cols-[minmax(0,1fr)_22rem]", "gap-x-16"] }, "connect-llm-agents");

await b.close();

// --- pad + convert to webp (part of the pipeline, so re-running regenerates the
// shipped assets) ---
// Give each tight crop a border in its OWN background colour (sampled above, so
// it's invisible) — breathing room so text never touches the edge. Tall lists
// (audit, the SSO form) keep only a top slice. `WxH>` resizes down only (never
// upscales a smaller crop). PAD is on the final image; it reads as ~20px once
// the doc scales the image into its column.
const PAD = 40, WIDTH = 1600, Q = 82;
const SHOTS = [
  { name: "policy-editor", out: "screenshots/policy-editor.webp" },
  { name: "audit-view", out: "screenshots/audit-view.webp", topCss: 700 },
  { name: "runbooks", out: "screenshots/runbooks.webp" },
  { name: "runner-fleet", out: "screenshots/runner-fleet.webp" },
  { name: "team-page", out: "screenshots/team-page.webp" },
  { name: "sso-add-connection", out: "docs/sso/sso-add-connection.webp", topCss: 850 },
  { name: "sso-directory-sync", out: "docs/sso/sso-directory-sync.webp" },
  { name: "connect-llm-agents", out: "screenshots/connect-llm-agents.webp", topCss: 720 },
];
for (const s of SHOTS) {
  const png = `${OUT}/${s.name}.png`;
  const dest = `${STATIC}/${s.out}`;
  const bg = bgColors[s.name] || "#09090b";
  const w = execSync(`magick identify -format "%w" "${png}"`).toString().trim();
  const crop = s.topCss ? `-crop ${w}x${s.topCss * 2}+0+0 +repage` : "";
  execSync(`magick "${png}" ${crop} -resize "${WIDTH}x>" -bordercolor "${bg}" -border ${PAD} -quality ${Q} "${dest}"`);
  console.log(`  → ${s.out}  (bg ${bg}, +${PAD}px)`);
}
console.log("done");
