from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        split = urlsplit(self.path)
        if split.path == "/health":
            body = b'{"ok":true}'
            content_type = "application/json"
            status = 200
        elif split.path == "/emisar-packtest-policy-status" and split.query == "policyStatus":
            body = (
                b'<?xml version="1.0" encoding="UTF-8"?>'
                b'<PolicyStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                b"<IsPublic>true</IsPublic>"
                b"</PolicyStatus>"
            )
            content_type = "application/xml"
            status = 200
        else:
            body = b"<Error><Code>NoSuchBucket</Code></Error>"
            content_type = "application/xml"
            status = 404

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
