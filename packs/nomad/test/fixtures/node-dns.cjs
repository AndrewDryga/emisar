// Real UDP DNS transport: forward normal queries to Docker DNS, but leave the
// hosts-file-only name unanswered to exercise an independent c-ares deadline.
const dgram = require("node:dgram");
const server = dgram.createSocket("udp4");
server.on("message", (query, peer) => {
  const labels = [];
  for (let offset = 12; offset < query.length && query[offset] > 0;) {
    const length = query[offset++];
    if (length > 63 || offset + length > query.length) return;
    labels.push(query.subarray(offset, offset + length).toString("ascii"));
    offset += length;
  }
  if (labels.join(".") === "stall.packtest.invalid") return;
  const forward = dgram.createSocket("udp4");
  const deadline = setTimeout(() => forward.close(), 3000);
  forward.on("error", () => { clearTimeout(deadline); forward.close(); });
  forward.once("message", response => {
    clearTimeout(deadline);
    server.send(response, peer.port, peer.address);
    forward.close();
  });
  forward.send(query, 53, "127.0.0.11");
});
server.bind(53, "127.0.0.1");
