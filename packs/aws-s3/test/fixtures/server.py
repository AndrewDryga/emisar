from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# A second object page, served only to a request carrying the exact cursor this
# fixture handed out, so a list case can prove the cursor reaches the service
# and the emitted next_page_cursor is a usable value rather than a redacted one.
OBJECT_PAGE_TWO = (
    b'<?xml version="1.0" encoding="UTF-8"?>'
    b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
    b"<Name>emisar-packtest-cursor</Name>"
    b"<Prefix>logs/</Prefix>"
    b"<KeyCount>1</KeyCount>"
    b"<MaxKeys>2</MaxKeys>"
    b"<IsTruncated>true</IsTruncated>"
    b"<ContinuationToken>cursor-in</ContinuationToken>"
    b"<NextContinuationToken>cursor-out</NextContinuationToken>"
    b"<Contents>"
    b"<Key>logs/page-two.txt</Key>"
    b"<LastModified>2026-07-27T12:00:00.000Z</LastModified>"
    b"<ETag>&quot;9d3c1e0a4f1d4b0e8f2a6c5b7d8e9f00&quot;</ETag>"
    b"<Size>17</Size>"
    b"<StorageClass>STANDARD</StorageClass>"
    b"</Contents>"
    b"</ListBucketResult>"
)


def object_page(query):
    params = parse_qs(query)
    if params.get("list-type") != ["2"]:
        return None
    if params.get("continuation-token") != ["cursor-in"]:
        return None
    return OBJECT_PAGE_TWO


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        split = urlsplit(self.path)
        page = None
        if split.path == "/emisar-packtest-cursor":
            page = object_page(split.query)
        if split.path == "/health":
            body = b'{"ok":true}'
            content_type = "application/json"
            status = 200
        elif page is not None:
            body = page
            content_type = "application/xml"
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
