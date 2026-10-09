"""HTTP response faults supplement, never replace, the real Vector pipeline."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import socket
from urllib.parse import urlsplit


def sample(value="3", extra="", component="fixture", metric="sent_events"):
    return (f'vector_component_{metric}_total{{component_id="{component}",'
            f'component_kind="source",component_type="demo"{extra}}} {value}\n')


def payload(mode):
    canary = os.environ["VECTOR_RESPONSE_CANARY"]
    if mode == "empty":
        return b""
    if mode == "comments":
        return b"# TYPE vector_component_sent_events_total counter\n"
    if mode == "unrelated":
        return f'other_metric{{private="{canary}"}} 100\n'.encode()
    if mode == "sum":
        return (sample("2", f',output="one",file="/private/config",auth="{canary}"') +
                sample("3", ',output="two",endpoint="https://private.invalid/path"') +
                sample("9", metric="sent_bytes")).encode()
    if mode == "zero":
        return sample("0").encode()
    if mode == "scientific":
        return sample("2.5e+2").encode()
    if mode == "timestamp":
        return sample("3 1791579684121").encode()
    if mode == "escaped":
        return sample("4", ',output="comma,brace}quote\\\"slash\\\\newline\\n"', 'escape,}\\\"\\\\\\n').encode()
    if mode == "duplicate":
        return (sample("2") +
                'vector_component_sent_events_total{component_type="demo",component_id="fixture",component_kind="source"} 3\n').encode()
    if mode == "duplicate-label":
        return sample("2", ',component_id="another"').encode()
    if mode == "missing-identity":
        return b'vector_component_sent_events_total{component_id="fixture"} 3\n'
    if mode == "empty-identity":
        return sample("3", component="").encode()
    if mode == "invalid-escape":
        return sample("3", ',output="invalid\\t"').encode()
    if mode == "unterminated":
        return b'vector_component_sent_events_total{component_id="unterminated} 3\n'
    if mode == "malformed-after-valid":
        return (sample("2") + sample(f"invalid-{canary}")).encode()
    if mode == "negative":
        return sample("-1").encode()
    if mode == "nonfinite":
        return sample("+Inf").encode()
    if mode == "overflow":
        return sample("1e309").encode()
    if mode == "aggregate-overflow":
        return (sample("1e308", ',output="one"') + sample("1e308", ',output="two"')).encode()
    if mode == "timestamp-overflow":
        return sample("3 9223372036854775808").encode()
    if mode == "extra-value":
        return sample("3 123 456").encode()
    if mode == "raw-over-cap":
        return b"#" + b"x" * 1048576 + b"\n" + sample().encode()
    if mode in ("output-over-cap", "near-cap"):
        lines = []
        size = 0
        i = 0
        value = "1e8" if mode == "output-over-cap" else "100000000"
        while True:
            line = sample(value, component=f"component_{i}").encode()
            if size + len(line) > 1040000:
                break
            lines.append(line)
            size += len(line)
            i += 1
        return b"".join(lines)
    if mode == 'url-quote"back\\slash':
        return sample("42", component="url_escaped").encode()
    if mode in ("missing", "redirect", "truncated", "chunked-over-cap"):
        return sample().encode()
    return b"unknown fixture route"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/health":
            mode = None
            body = b"healthy"
        else:
            mode = path.removeprefix("/")
            body = payload(mode)
        status = 200
        if mode == "missing":
            status = 404
        elif mode == "unavailable":
            status = 503
            body = os.environ["VECTOR_RESPONSE_CANARY"].encode()
        elif mode == "redirect":
            status = 302
        self.send_response(status)
        if mode == "redirect":
            self.send_header("Location", "/sum")
        if mode != "chunked-over-cap":
            self.send_header("Content-Length", str(len(body) + (100 if mode == "truncated" else 0)))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            if mode == "chunked-over-cap":
                block = b"#" + b"x" * 16383
                for _ in range(65):
                    self.wfile.write(b"4000\r\n" + block + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(body)
            self.wfile.flush()
            if mode == "truncated":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
