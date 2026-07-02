import puppeteer from "puppeteer-core";
import { resolve } from "node:path";
const BASE = "http://localhost:4000", SLUG = "demo";
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = resolve("/Users/andrewdryga/Projects/os/emisar/portal/.agent/screenshots");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function login(page) {
  // Magic links are one-use AND browser-nonce-bound, so we must open the
  // message THIS request produced — diff the mailbox before/after and poll
  // until the new message lands (email delivery is async).
  const mailboxLinks = async () => {
    await page.goto(`${BASE}/dev/mailbox`, { waitUntil: "networkidle2" });
    const links = await page.$$eval("a[href]", (as) => as.map((a) => a.getAttribute("href")));
    return links.filter((h) => h && /mailbox\/.+/.test(h) && !h.endsWith("/mailbox"));
  };

  const before = await mailboxLinks();

  await page.goto(`${BASE}/sign_in`, { waitUntil: "networkidle2" });
  await page.type('input[name="user[email]"]', "demo@emisar.dev");
  await Promise.all([
    page.waitForNavigation({ waitUntil: "networkidle2" }).catch(() => {}),
    page.keyboard.press("Enter"),
  ]);

  let fresh = null;
  for (let i = 0; i < 15 && !fresh; i++) {
    await sleep(1000);
    const after = await mailboxLinks();
    fresh = after.find((h) => !before.includes(h));
  }
  if (!fresh) throw new Error("no new mailbox message after requesting the magic link");

  await page.goto(new URL(fresh, BASE).href, { waitUntil: "networkidle2" });
  let hit = null;
  for (const f of page.frames()) {
    try {
      const m = (await f.content()).match(/\/sign_in\/magic\/[A-Za-z0-9_-]+\/[A-Za-z0-9_.~%-]+/);
      if (m) { hit = m[0]; break; }
    } catch {}
  }
  if (!hit) hit = (await page.content()).match(/\/sign_in\/magic\/[A-Za-z0-9_-]+\/[A-Za-z0-9_.~%-]+/)?.[0];
  if (!hit) throw new Error("no magic link in the fresh message");
  await page.goto(new URL(hit, BASE).href, { waitUntil: "networkidle2" });
  await sleep(1000);
}

// The Paddle checkout renders inside a sandbox-buy.paddle.com iframe. Selectors
// differ across versions, so try a testid, a name, and a placeholder variant —
// and dump the frame's inventory when something is missing so the next run can adapt.
async function paddleFrame(page) {
  for (let i = 0; i < 60; i++) {
    const frame = page.frames().find((f) => /buy\.paddle\.com/.test(f.url()));
    if (frame) return frame;
    await sleep(1000);
  }
  throw new Error("paddle checkout iframe never appeared");
}

async function dumpInventory(frame, label) {
  const inv = await frame.evaluate(() =>
    [...document.querySelectorAll("input, button, select")].map((el) => ({
      tag: el.tagName,
      type: el.type || null,
      name: el.name || null,
      id: el.id || null,
      testid: el.getAttribute("data-testid"),
      placeholder: el.placeholder || null,
      text: el.tagName === "BUTTON" ? el.textContent.trim().slice(0, 40) : null,
    }))
  );
  console.log(`--- frame inventory (${label}) ---`);
  console.log(JSON.stringify(inv, null, 1));
}

async function fillIn(frame, candidates, value, label) {
  for (const sel of candidates) {
    const el = await frame.$(sel);
    if (el) {
      await el.click({ clickCount: 3 });
      await el.type(value, { delay: 20 });
      console.log(`  ✓ filled ${label} via ${sel}`);
      return true;
    }
  }
  console.log(`  ✗ ${label}: no selector matched`);
  return false;
}

const b = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  args: ["--no-sandbox", "--force-prefers-reduced-motion"],
});
try {
  const page = await b.newPage();
  await page.setViewport({ width: 1440, height: 1024, deviceScaleFactor: 1 });
  await login(page);

  await page.goto(`${BASE}/app/${SLUG}/settings/billing`, { waitUntil: "networkidle2" });
  await sleep(1500);
  await page.screenshot({ path: resolve(OUT, "e2e-1-billing.png") });

  // The LV pushes an external redirect on click, which can destroy the
  // evaluate context mid-call — that error IS the success signal.
  try {
    const clicked = await page.evaluate(() => {
      const btn = document.querySelector("button[phx-click='upgrade'][phx-value-plan='team']");
      if (btn) btn.click();
      return !!btn;
    });
    if (!clicked) throw new Error("no Upgrade-to-team button on billing page");
  } catch (error) {
    if (!/Execution context was destroyed/.test(String(error))) throw error;
  }
  console.log("clicked Upgrade to Team — waiting for /checkout redirect");

  for (let i = 0; i < 30 && !page.url().includes("/checkout"); i++) await sleep(1000);
  console.log("landed on:", page.url());
  if (!page.url().includes("_ptxn=")) throw new Error(`expected ?_ptxn= url, got ${page.url()}`);

  const frame = await paddleFrame(page);
  console.log("paddle frame:", frame.url().slice(0, 90));
  await sleep(4000);
  await page.screenshot({ path: resolve(OUT, "e2e-2-overlay.png") });
  await dumpInventory(frame, "on open");

  // Some checkouts ask for email + country first (customer prefill usually skips it).
  const emailFilled = await fillIn(
    frame,
    ['input[name="email"]', '[data-testid="authenticationEmailInput"]', 'input[type="email"]'],
    "demo@emisar.dev",
    "email"
  );
  const postcode1 = await fillIn(
    frame,
    ['input[name="postcode"]', '[data-testid="postcodeInput"]'],
    "90210",
    "postcode (step 1)"
  );
  if (emailFilled || postcode1) {
    const cont = await frame.$('button[type="submit"]');
    if (cont) {
      await cont.click();
      console.log("  submitted identity step");
      await sleep(4000);
      await dumpInventory(frame, "after identity step");
    }
  }

  await fillIn(
    frame,
    ['input[name="cardNumber"]', '[data-testid="cardNumberInput"]', 'input[id="cardNumber"]'],
    "4242424242424242",
    "card number"
  );
  await fillIn(
    frame,
    ['input[name="cardholderName"]', '[data-testid="cardholderNameInput"]'],
    "Demo Operator",
    "cardholder"
  );
  await fillIn(
    frame,
    ['input[name="expiryDate"]', '[data-testid="cardExpiryInput"]', 'input[name="cardExpiry"]'],
    "12/30",
    "expiry"
  );
  await fillIn(
    frame,
    [
      'input[name="verificationValue"]',
      '[data-testid="cardVerificationValueInput"]',
      'input[name="cvv"]',
    ],
    "100",
    "cvc"
  );
  await fillIn(frame, ['input[name="postcode"]', '[data-testid="postcodeInput"]'], "90210", "postcode");
  await page.screenshot({ path: resolve(OUT, "e2e-3-filled.png") });

  const paid = await frame.evaluate(() => {
    const btn = [...document.querySelectorAll("button")].find(
      (candidate) =>
        candidate.type === "submit" || /pay|subscribe|start/i.test(candidate.textContent)
    );
    if (btn) btn.click();
    return btn ? btn.textContent.trim().slice(0, 40) : null;
  });
  console.log("clicked pay button:", paid);

  // Success = Paddle redirects the top page to our successUrl → billing page.
  for (let i = 0; i < 45; i++) {
    if (page.url().includes("/settings/billing")) break;
    await sleep(2000);
  }
  await sleep(2000);
  await page.screenshot({ path: resolve(OUT, "e2e-4-after-payment.png") });
  console.log("final url:", page.url());
} finally {
  await b.close();
}
