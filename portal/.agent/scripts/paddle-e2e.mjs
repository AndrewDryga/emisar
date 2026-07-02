import puppeteer from "puppeteer-core";
import { resolve } from "node:path";
const BASE = process.env.E2E_BASE || "http://localhost:4000", SLUG = "demo";
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

// The Paddle checkout renders inside a sandbox-buy.paddle.com iframe, and the
// CARD fields live in nested per-field iframes inside it (the PCI hosted-field
// pattern) — so every fill/click searches ALL paddle frames, and the
// inventories are dumped per frame so a changed layout is diagnosable from
// the run log alone.
async function paddleFrame(page) {
  for (let i = 0; i < 60; i++) {
    const frame = page.frames().find((f) => /buy\.paddle\.com/.test(f.url()));
    if (frame) return frame;
    await sleep(1000);
  }
  throw new Error("paddle checkout iframe never appeared");
}

function paddleFrames(page) {
  return page.frames().filter((f) => /paddle\.com/.test(f.url()));
}

async function dumpInventory(page, label) {
  console.log(`--- frames (${label}) ---`);
  for (const frame of paddleFrames(page)) {
    let inv = [];
    try {
      inv = await frame.evaluate(() =>
        [...document.querySelectorAll("input, button, select")].map((el) =>
          [
            el.tagName,
            el.name || "",
            el.getAttribute("data-testid") || "",
            el.placeholder || "",
            el.tagName === "BUTTON" ? el.textContent.trim().slice(0, 30) : "",
          ].join("|")
        )
      );
    } catch {}
    if (inv.length) console.log(frame.url().slice(0, 80), "\n   ", inv.join("\n    "));
  }
}

async function fillIn(page, candidates, value, label) {
  for (let attempt = 0; attempt < 10; attempt++) {
    for (const frame of paddleFrames(page)) {
      for (const sel of candidates) {
        const el = await frame.$(sel).catch(() => null);
        if (!el) continue;

        const current = await el.evaluate((node) => node.value).catch(() => null);
        if (current === value) {
          console.log(`  ✓ ${label} already "${value}"`);
          return true;
        }

        // React-controlled inputs ignore a plain .value= — clear through the
        // native setter + input event, then type (triple-click select-all
        // doesn't reliably take here, which is how fills end up doubled).
        await el.click();
        await el.evaluate((node) => {
          const setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype,
            "value"
          ).set;
          setter.call(node, "");
          node.dispatchEvent(new Event("input", { bubbles: true }));
        });
        await el.type(value, { delay: 20 });

        const after = await el.evaluate((node) => node.value).catch(() => null);
        console.log(`  ✓ filled ${label} via ${sel} (now "${after}")`);
        return after === value;
      }
    }
    await sleep(1000);
  }
  console.log(`  ✗ ${label}: no selector matched in any paddle frame`);
  return false;
}

// True when `selector` exists in any paddle frame right now.
async function present(page, selector) {
  for (const frame of paddleFrames(page)) {
    if (await frame.$(selector).catch(() => null)) return true;
  }
  return false;
}

async function clickIn(page, candidates, label) {
  for (const frame of paddleFrames(page)) {
    for (const sel of candidates) {
      const el = await frame.$(sel).catch(() => null);
      if (el) {
        await el.click();
        console.log(`  ✓ clicked ${label} via ${sel}`);
        return true;
      }
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

  // Paddle stores the sandbox default payment link as httpS://localhost:4000
  // (its form forces the scheme), but this machine blocks browser TLS to
  // private addresses — so rewrite that one forced-https hop back to the
  // plain-http dev server in flight. Everything else runs http already.
  await page.setRequestInterception(true);
  page.on("request", (request) => {
    const url = request.url();
    if (url.startsWith("https://localhost:4000/")) {
      return request.respond({
        status: 302,
        headers: { location: url.replace("https://", "http://") },
      });
    }
    return request.continue();
  });

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
  await sleep(6000);
  await page.screenshot({ path: resolve(OUT, "e2e-2-overlay.png") });
  await dumpInventory(page, "on open");

  // Step 1 — identity: email + country, advanced by its own named submit
  // (the quantity-picker +/- are ALSO type=submit, so never click "first
  // submit"). The email is usually prefilled from the attached customer.
  await fillIn(
    page,
    ['[data-testid="authenticationEmailInput"]', 'input[name="email"]'],
    "demo@emisar.dev",
    "email"
  );
  for (const f of paddleFrames(page)) {
    if (await f.$('select[name="countryCode"]').catch(() => null)) {
      await f.select('select[name="countryCode"]', "US");
      console.log("  ✓ country -> US");
      break;
    }
  }

  // Continue reveals ZIP for US on the same form; fill it and Continue again
  // until the identity form actually yields to the payment step.
  for (let round = 0; round < 4; round++) {
    if (!(await present(page, '[data-testid="authenticationEmailInput"]'))) break;

    if (await present(page, '[data-testid="postcodeInput"]')) {
      await fillIn(page, ['[data-testid="postcodeInput"]'], "90210", "postcode");
    }

    await clickIn(
      page,
      ['[data-testid="combinedAuthenticationLocationFormSubmitButton"]'],
      `identity Continue (round ${round + 1})`
    );
    await sleep(6000);
  }
  await dumpInventory(page, "payment step");

  // US buyers must tick the recurring-charge consent — do it BEFORE the card
  // fill (a rejected submit re-renders the form and can drop typed fields),
  // and through a JS click: the input is styled/overlaid, so a coordinate
  // click reports success without toggling it. Verify .checked, never trust
  // the click.
  for (const f of paddleFrames(page)) {
    const checked = await f
      .$eval('[data-testid="us-compliance-checkbox"]', (el) => {
        if (!el.checked) el.click();
        return el.checked;
      })
      .catch(() => null);
    if (checked !== null) {
      console.log("  recurring-consent checked:", checked);
      break;
    }
  }

  // Step 2 — the card form; each field may live in its own nested iframe.
  await fillIn(
    page,
    ['[data-testid="cardNumberInput"]', 'input[name="cardNumber"]', 'input[id="cardNumber"]'],
    "4242424242424242",
    "card number"
  );
  await fillIn(
    page,
    ['[data-testid="cardholderNameInput"]', 'input[name="cardholderName"]', 'input[name="name"]'],
    "Demo Operator",
    "cardholder"
  );
  await fillIn(
    page,
    ['[data-testid="expiryDateField"]', 'input[name="expiry"]', '[data-testid="cardExpiryInput"]'],
    "12/30",
    "expiry"
  );
  await fillIn(
    page,
    [
      '[data-testid="cardVerificationValueInput"]',
      'input[name="verificationValue"]',
      'input[name="cvv"]',
    ],
    "100",
    "cvc"
  );
  if (await present(page, '[data-testid="postcodeInput"]')) {
    await fillIn(page, ['[data-testid="postcodeInput"]'], "90210", "postcode (card step)");
  }
  await page.screenshot({ path: resolve(OUT, "e2e-3-filled.png") });

  // The pay button is the one whose LABEL says pay/subscribe (never a bare
  // first-submit — see the quantity picker above).
  let paid = null;
  for (const f of paddleFrames(page)) {
    paid = await f
      .evaluate(() => {
        const buttons = [...document.querySelectorAll("button")];
        const byTestid = buttons.find((b) =>
          /paymentformsubmit/i.test(b.getAttribute("data-testid") || "")
        );
        const byText = buttons.find((b) => /pay|subscribe|start trial/i.test(b.textContent));
        const btn = byTestid || byText;
        if (btn) btn.click();
        return btn ? (btn.textContent.trim() || btn.getAttribute("data-testid")).slice(0, 50) : null;
      })
      .catch(() => null);
    if (paid) break;
  }
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
