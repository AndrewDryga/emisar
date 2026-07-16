import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// Chrome flags that make a headless launch survive inside a container: the box's
// /dev/shm is tiny (Chromium's default shared-memory path → crashpad crash), there's
// no GPU, and the box already IS the sandbox. All three are harmless on the macOS host,
// so the scripts pass them everywhere. Spread into puppeteer.launch({ args }).
export const containerChromeArgs = [
  "--no-sandbox",
  "--disable-dev-shm-usage",
  "--disable-gpu",
];

// Resolve a Chrome/Chromium executable for puppeteer-core across the macOS host and a
// coop box. Order: explicit $CHROME → macOS Google Chrome (the host default) → a
// Playwright-installed Chromium (the coop box bakes one at $PLAYWRIGHT_BROWSERS_PATH;
// see Dockerfile.agent). Throws with a fix hint when nothing is found, so a missing
// browser fails loudly instead of puppeteer's opaque spawn error.
export function resolveChrome() {
  if (process.env.CHROME) return process.env.CHROME;

  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ];
  const pwRoot =
    process.env.PLAYWRIGHT_BROWSERS_PATH ||
    join(homedir(), ".cache", "ms-playwright");
  if (existsSync(pwRoot)) {
    for (const dir of readdirSync(pwRoot)
      .filter((n) => n.startsWith("chromium"))
      .sort()
      .reverse()) {
      candidates.push(
        join(pwRoot, dir, "chrome-linux", "chrome"),
        join(pwRoot, dir, "chrome-linux64", "chrome"),
      );
    }
  }

  const found = candidates.find((p) => existsSync(p));
  if (found) return found;
  throw new Error(
    "no Chrome/Chromium found — set CHROME=/path/to/chrome, or install one: npx playwright install chromium",
  );
}
