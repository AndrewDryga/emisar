#!/bin/sh
set -eu
namespace=$1
task=$2
alloc_id=$3
hostname=$4
seconds=$5

# The program is part of the trusted pack hash; inputs stay separate argv.
program='
const dns = require("node:dns");
const fs = require("node:fs");
const net = require("node:net");
const hostname = process.argv[1];
const seconds = Number(process.argv[2]);
const started = process.hrtime.bigint();
const elapsed = () => Math.round(Number(process.hrtime.bigint() - started) / 1e6);
const errorCode = error => /^[A-Z0-9_]{1,64}$/.test(error.code || "") ? error.code : "DNS_ERROR";
const result = {
  scope: "fresh_node_process_in_task", node_version: process.version, timed_out: false,
  hostname, resolv_conf: {nameservers: [], search: [], options: [], truncated: false},
  node_servers: dns.getServers().slice(0, 16),
  lookup: {error: "TIMEOUT"}, resolve4: {error: "TIMEOUT"}, resolve6: {error: "TIMEOUT"}
};
let fd;
try {
  fd = fs.openSync("/etc/resolv.conf", fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  if (!fs.fstatSync(fd).isFile()) throw {code: "NOT_REGULAR_FILE"};
  const buffer = Buffer.alloc(4097);
  const count = fs.readSync(fd, buffer, 0, buffer.length, 0);
  result.resolv_conf.truncated = count > 4096;
  const contents = buffer.subarray(0, Math.min(count, 4096)).toString("utf8");
  // Never return raw file text, comments, or unrecognized directives.
  for (const line of contents.split("\n")) {
    const [name, ...values] = line.split(/[;#]/, 1)[0].trim().split(/\s+/);
    if (name === "nameserver" && net.isIP(values[0])) result.resolv_conf.nameservers.push(values[0]);
    if (name === "search" || name === "domain") {
      result.resolv_conf.search.push(...values.filter(value => /^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/.test(value)));
    }
    if (name === "options") {
      result.resolv_conf.options.push(...values.filter(value => /^(ndots:[0-9]{1,2}|timeout:[0-9]{1,2}|attempts:[0-9]{1,2}|rotate|single-request|single-request-reopen|use-vc|edns0|trust-ad|no-aaaa)$/.test(value)));
    }
  }
  for (const field of ["nameservers", "search", "options"]) {
    if (result.resolv_conf[field].length > 16) result.resolv_conf.truncated = true;
    result.resolv_conf[field] = result.resolv_conf[field].slice(0, 16);
  }
} catch (error) {
  result.resolv_conf.error = errorCode(error);
} finally {
  if (fd !== undefined) fs.closeSync(fd);
}
let remaining = 3;
let finished = false;
function finish() {
  if (finished) return;
  finished = true;
  result.elapsed_ms = elapsed();
  // Exit after flushing: getaddrinfo cannot be cancelled and must not outlive
  // the deadline when a resolver is unresponsive.
  process.stdout.write(JSON.stringify(result) + "\n", () => process.exit(result.timed_out || result.lookup.error ? 1 : 0));
}
const deadline = setTimeout(() => { result.timed_out = true; finish(); }, seconds * 1000);
function capture(name, error, addresses) {
  if (finished) return;
  result[name] = error ? {error: errorCode(error)} : {addresses: addresses.slice(0, 16), truncated: addresses.length > 16};
  if (--remaining === 0) { clearTimeout(deadline); finish(); }
}
dns.lookup(hostname, {all: true}, (error, addresses) => capture("lookup", error, addresses));
dns.resolve4(hostname, (error, addresses) => capture("resolve4", error, addresses));
dns.resolve6(hostname, (error, addresses) => capture("resolve6", error, addresses));
'

# Task runtime configuration may preload code, log request data, or write
# coverage/cache files. Preserve its trusted CA settings, but disable those
# hooks before Node starts. No shell or user-supplied code runs in the task.
exec nomad alloc exec ${namespace:+-namespace="$namespace"} -i=false -t=false \
  -task "$task" "$alloc_id" env -u NODE_OPTIONS -u NODE_DEBUG -u NODE_DEBUG_NATIVE \
  -u NODE_V8_COVERAGE -u NODE_COMPILE_CACHE NODE_DISABLE_COMPILE_CACHE=1 \
  node --no-warnings --input-type=commonjs -e "$program" -- "$hostname" "$seconds"
