import assert from "node:assert/strict";
import test from "node:test";
import { developmentCertificateArgs } from "./resolve-chrome.mjs";

test("omits a certificate exception when no development SPKI is configured", () => {
  assert.deepEqual(developmentCertificateArgs(""), []);
});

test("scopes the certificate exception to one exact SPKI hash", () => {
  const spki = "35dWCminPccy/YZ4zOu6pzuUCG5xGKQSGwi3fj9eyfY=";

  assert.deepEqual(developmentCertificateArgs(spki), [
    `--ignore-certificate-errors-spki-list=${spki}`,
  ]);
});

test("rejects malformed SPKI values instead of forwarding browser flags", () => {
  assert.throws(
    () => developmentCertificateArgs("hash --ignore-certificate-errors"),
    /must be a base64 SHA-256 SPKI hash/,
  );
});
