#!/bin/sh
set -eu
namespace=$1
task=$2
alloc_id=$3
url=$4
seconds=$5

program='
const https = require("node:https");
const started = process.hrtime.bigint();
const elapsed = () => Math.round(Number(process.hrtime.bigint() - started) / 1e6);
const result = {
  scope: "fresh_node_process_in_task", node_version: process.version,
  method: "GET", tls_verified: false, status: null, timings_ms: {}
};
let finished = false;
let request;
let deadline;
function finish(error) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  if (error) result.error = /^[A-Z0-9_]{1,64}$/.test(error.code || "") ? error.code : "HTTPS_ERROR";
  result.timings_ms.total = elapsed();
  if (request) request.destroy();
  const exit = error ? 1 : 0;
  process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(exit));
}
try {
  const url = new URL(process.argv[1]);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    finish({code: "INVALID_URL"});
  } else {
    deadline = setTimeout(() => finish({code: "TIMEOUT"}), Number(process.argv[2]) * 1000);
    request = https.request(url, {
      method: "GET", agent: false, rejectUnauthorized: true,
      maxHeaderSize: 8192, headers: {Connection: "close"}
    }, response => {
      result.status = response.statusCode;
      result.timings_ms.headers = elapsed();
      // Never consume or print the body, response headers, redirects, or URL.
      response.destroy();
      finish();
    });
    request.on("socket", socket => {
      socket.once("lookup", () => { result.timings_ms.lookup = elapsed(); });
      socket.once("connect", () => { result.timings_ms.connect = elapsed(); });
      socket.once("secureConnect", () => {
        result.timings_ms.tls = elapsed();
        result.tls_verified = socket.authorized;
      });
    });
    request.once("error", finish);
    request.end();
  }
} catch (error) {
  finish(error);
}
'

exec nomad alloc exec ${namespace:+-namespace="$namespace"} -i=false -t=false \
  -task "$task" "$alloc_id" env -u NODE_OPTIONS -u NODE_DEBUG -u NODE_DEBUG_NATIVE \
  -u NODE_V8_COVERAGE -u NODE_COMPILE_CACHE -u NODE_USE_ENV_PROXY \
  -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
  NODE_DISABLE_COMPILE_CACHE=1 \
  node --no-warnings --input-type=commonjs -e "$program" -- "$url" "$seconds"
