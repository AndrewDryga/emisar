import puppeteer from "puppeteer-core";
import { existsSync, readFileSync } from "node:fs";
import {
  resolveChrome,
  containerChromeArgs,
  developmentCertificateArgs,
} from "./resolve-chrome.mjs";

export async function acquireBrowser({ profile } = {}) {
  const state = process.env.BROWSER_STATE;
  if (state && existsSync(state)) {
    try {
      const { wsEndpoint } = JSON.parse(readFileSync(state, "utf8"));
      const browser = await puppeteer.connect({ browserWSEndpoint: wsEndpoint });
      return { browser, shared: true };
    } catch {
      // A stale state file should not block proof; launch a disposable browser.
    }
  }

  const browser = await puppeteer.launch({
    executablePath: resolveChrome(),
    headless: "new",
    userDataDir: profile,
    args: [
      ...containerChromeArgs,
      ...developmentCertificateArgs(),
      "--force-prefers-reduced-motion",
    ],
  });
  return { browser, shared: false };
}

export async function releaseBrowser(browser, shared) {
  if (shared) browser.disconnect();
  else await browser.close();
}
