"""Metrics protocol faults and busy scrapes; native behavior uses real Traefik."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


SMALL = b"""# HELP traefik_config_reloads_total Reload count.
# TYPE traefik_config_reloads_total counter
traefik_config_reloads_total 3
traefik_config_last_reload_success 1
traefik_service_request_duration_seconds_bucket{le="1"} 2
traefik_service_request_duration_seconds_bucket{le="+Inf"} 4
traefik_service_request_duration_seconds_sum 3.5
traefik_service_request_duration_seconds_count 4
go_goroutines 7
"""
AUTH = "reader:packtest-canary-traefik-metrics-password-710a"


class Handler(BaseHTTPRequestHandler):
    metrics_requests = 0

    def do_GET(self):
        if self.path == "/health":
            return self.respond(b"ok")
        if self.path == "/stats":
            return self.respond(json.dumps({"metrics_requests": Handler.metrics_requests}).encode())
        Handler.metrics_requests += 1
        route = self.path.split("/")[1]
        if route == "http-error":
            return self.respond(b"packtest-canary-traefik-error-secret-6f8d", 503)
        if route == "auth":
            expected = "Basic " + base64.b64encode(AUTH.encode()).decode()
            if self.headers.get("Authorization") != expected:
                return self.respond(b"unauthorized", 401)
        if route == "large":
            rows = [b"traefik_config_reloads_total 3\n", b"traefik_config_last_reload_success 1\n"]
            rows.extend(
                (f'traefik_service_requests_total{{service="busy-{i}@file",code="200",method="GET",padding="' + "x" * 80 + '"} 1\n').encode()
                for i in range(12000)
            )
            rows.extend(f'traefik_service_request_duration_seconds_bucket{{service="busy-{i}@file",le="+Inf"}} 1\n'.encode() for i in range(1000))
            return self.respond(b"".join(rows))
        if route == "long-samples":
            return self.respond("".join(f'traefik_sample{{id="{i}",label="' + "λ" * 8000 + '"} 1\n' for i in range(10)).encode())
        if route == "oversized":
            # Deliberately no Content-Length: input bounds cannot trust it.
            self.send_response(200)
            self.end_headers()
            try:
                self.wfile.write(b"#" + b"x" * (9 * 1024 * 1024) + b"\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if route in ("slow", "partial"):
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b"traefik_config_reloads_total 3\n")
            self.wfile.flush()
            if route == "slow":
                time.sleep(22)
            self.close_connection = True
            return
        if route == "invalid":
            return self.respond(b"<html>wrong listener</html>\n")
        return self.respond(SMALL)

    def respond(self, body, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
