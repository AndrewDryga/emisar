import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { PUPPETEER_REVISIONS } from "puppeteer-core";

if (process.env.CHROME && existsSync(process.env.CHROME)) {
  console.log(`using CHROME=${process.env.CHROME}`);
  process.exit(0);
}

if (
  process.platform === "darwin" &&
  existsSync("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
) {
  console.log("using the host Google Chrome installation");
  process.exit(0);
}

if (process.platform === "linux" && process.arch === "arm64") {
  if (existsSync("/usr/bin/chromium-headless-shell") || existsSync("/usr/bin/chromium")) {
    console.log("using the system ARM64 Chromium installation");
    process.exit(0);
  }
  throw new Error(
    "Chrome for Testing does not publish Linux ARM64 builds; install chromium-headless-shell or set CHROME",
  );
}

const cache = process.env.PUPPETEER_CACHE_DIR ?? join(homedir(), ".cache", "puppeteer");
const build = PUPPETEER_REVISIONS["chrome-headless-shell"];
const cli = join(import.meta.dirname, "node_modules", "@puppeteer", "browsers", "lib", "main-cli.js");
mkdirSync(cache, { recursive: true });

const result = spawnSync(
  process.execPath,
  [cli, "install", `chrome-headless-shell@${build}`, "--path", cache],
  { stdio: "inherit" },
);
if (result.error) throw result.error;
process.exit(result.status ?? 1);
