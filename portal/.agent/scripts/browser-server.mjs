import puppeteer from "puppeteer-core";
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import {
  resolveChrome,
  containerChromeArgs,
  developmentCertificateArgs,
} from "./resolve-chrome.mjs";

const state = process.env.BROWSER_STATE;
if (!state) throw new Error("BROWSER_STATE is required");
mkdirSync(dirname(state), { recursive: true });
const tlsSpki = process.env.EMISAR_DEV_TLS_SPKI;

const browser = await puppeteer.launch({
  executablePath: resolveChrome(),
  headless: "new",
  userDataDir: process.env.BROWSER_PROFILE ?? process.env.PROFILE_DIR,
  args: [
    ...containerChromeArgs,
    ...developmentCertificateArgs(tlsSpki),
    "--force-prefers-reduced-motion",
  ],
});
if (process.env.BROWSER_TLS_MARKER) {
  writeFileSync(process.env.BROWSER_TLS_MARKER, tlsSpki, { mode: 0o600 });
}

const tmp = `${state}.${process.pid}`;
writeFileSync(
  tmp,
  JSON.stringify({
    pid: process.pid,
    browserPid: browser.process()?.pid,
    wsEndpoint: browser.wsEndpoint(),
    tlsSpki,
  }),
  { mode: 0o600 },
);
renameSync(tmp, state);

let closing = false;
const keepAlive = setInterval(() => {}, 60_000);
const shutdown = async () => {
  if (closing) return;
  closing = true;
  clearInterval(keepAlive);
  rmSync(state, { force: true });
  await browser.close().catch(() => {});
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
browser.on("disconnected", () => {
  rmSync(state, { force: true });
  process.exit(0);
});
