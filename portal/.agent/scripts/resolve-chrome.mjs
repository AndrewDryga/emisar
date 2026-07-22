import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { Browser, computeExecutablePath } from "@puppeteer/browsers";
import { PUPPETEER_REVISIONS } from "puppeteer-core";

// Chrome flags that make a headless launch survive inside a container: the box's
// /dev/shm is tiny (Chromium's default shared-memory path → crashpad crash), there's
// no GPU, and the box already IS the sandbox. All three are harmless on the macOS host,
// so the scripts pass them everywhere. Spread into puppeteer.launch({ args }).
export const containerChromeArgs = [
  "--no-sandbox",
  "--disable-dev-shm-usage",
  "--disable-gpu",
];

export function developmentCertificateArgs(spki = process.env.EMISAR_DEV_TLS_SPKI) {
  if (!spki) return [];
  if (!/^[A-Za-z0-9+/]{43}=$/.test(spki)) {
    throw new Error("EMISAR_DEV_TLS_SPKI must be a base64 SHA-256 SPKI hash");
  }
  return [`--ignore-certificate-errors-spki-list=${spki}`];
}

// Resolve a Chrome/Chromium executable for puppeteer-core across the macOS host and a
// coop box. Order: explicit $CHROME → macOS Google Chrome (the host default) → a
// pinned Puppeteer headless shell, a distro-native shell (ARM Coop boxes), then
// a Playwright-installed Chromium. Throws with a fix hint when nothing is found.
export function resolveChrome() {
  if (process.env.CHROME) return process.env.CHROME;

  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    computeExecutablePath({
      cacheDir: process.env.PUPPETEER_CACHE_DIR || join(homedir(), ".cache", "puppeteer"),
      browser: Browser.CHROMEHEADLESSSHELL,
      buildId: PUPPETEER_REVISIONS["chrome-headless-shell"],
    }),
    "/usr/bin/chromium-headless-shell",
    "/usr/bin/chromium",
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
    "no Chrome/Chromium found — set CHROME=/path/to/chrome, or run: dev/run browser install",
  );
}
