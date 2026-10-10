"""Disposable RDAP wire fixture: real HTTP, deliberately hostile documents."""
import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = "http://rdap-api:8080/rdap/"
CANARY = "packtest-canary-rdap-contact-62c37"
state = {"scenario": "normal", "requests": [], "whois": []}
SCENARIOS = {
    "normal", "minimal", "suffix", "candidates", "mixed-controls", "bad-newline", "bad-nul", "bad-base", "bad-bootstrap", "no-service",
    "bootstrap-redirect", "bootstrap-error", "bootstrap-large", "redirect",
    "error", "error-object", "wrong-name", "multi", "malformed", "bad-events",
    "bad-registrar", "bad-nameservers", "exact", "large", "chunked-large", "clip", "controls",
}


def domain(name):
    return {
        "objectClassName": "domain", "ldhName": name,
        "entities": [
            {"objectClassName": "entity", "roles": ["registrar"],
             "vcardArray": ["vcard", [["fn", {}, "text", "Fixture RDAP Registrar"],
                                      ["email", {}, "text", CANARY],
                                      ["categories", {}, "text", "computers", "cameras"]]],
             "publicIds": [{"type": "IANA Registrar ID", "identifier": "9999"}],
             "events": [{"eventAction": "contact", "eventDate": CANARY}],
             "entities": [{"roles": ["registrant"], "handle": CANARY}]},
            {"roles": ["registrant"], "vcardArray": ["vcard", [["fn", {}, "text", CANARY]]]},
        ],
        "events": [{"eventAction": "registration", "eventDate": "2020-01-02T03:04:05Z", "eventActor": CANARY},
                   {"eventAction": "expiration", "eventDate": "2030-01-02T03:04:05Z"}],
        "nameservers": [{"objectClassName": "nameserver", "ldhName": "ns1.example.dev", "remarks": [CANARY]}],
        "remarks": [{"description": [CANARY]}],
        "links": [{"rel": "related", "href": "http://rdap-api:8080/contact?value=" + CANARY}],
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send(self, code, data, headers=None, chunked=False):
        payload = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/rdap+json")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(payload)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            if chunked:
                for offset in range(0, len(payload), 65536):
                    part = payload[offset:offset + 65536]
                    self.wfile.write(("%x\r\n" % len(part)).encode() + part + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if self.path.startswith("/_select/"):
            scenario = self.path.removeprefix("/_select/")
            if scenario not in SCENARIOS:
                return self.send(400, {"errorCode": 400})
            state.update(scenario=scenario, requests=[], whois=[])
            return self.send(200, {"selected": scenario})
        if self.path.startswith("/_whois/"):
            state["whois"].append(self.path.removeprefix("/_whois/"))
            return self.send(200, {})
        self.send(404, {"errorCode": 404})

    def do_GET(self):
        if self.path == "/health":
            return self.send(200, {})
        if self.path == "/_observe":
            return self.send(200, copy.deepcopy(state))
        state["requests"].append(self.path)
        scenario = state["scenario"]
        if self.path == "/bootstrap.json":
            if scenario == "bootstrap-error":
                return self.send(503, {"errorCode": 503, "description": [CANARY]})
            if scenario == "bootstrap-redirect":
                return self.send(302, {}, {"Location": BASE + "domain/example.dev"})
            if scenario == "bootstrap-large":
                return self.send(200, b"x" * 16777217)
            if scenario == "bad-bootstrap":
                return self.send(200, {"services": {"dev": BASE}})
            services = [[["dev"], [BASE]]]
            if scenario == "no-service":
                services = [[["com"], [BASE]]]
            if scenario == "bad-base":
                services = [[["dev"], ["http://rdap-api:8080/rdap/{a,b}/"]]]
            if scenario == "candidates":
                services = [[["dev"], ["http://unselected.invalid/rdap/", BASE]]]
            if scenario in {"mixed-controls", "bad-newline", "bad-nul"}:
                urls = [BASE + "\n"] if scenario == "bad-newline" else [BASE + "\x00"]
                if scenario == "mixed-controls":
                    urls = [BASE + "\n", BASE + "\x00", BASE]
                services = [[["dev"], urls]]
            if scenario == "suffix":
                services = [[["dev"], ["https://unselected.invalid/rdap/"]],
                            [["notexample.dev"], ["https://not-a-label-match.invalid/"]],
                            [["example.dev"], [BASE]]]
            return self.send(200, {"version": "1.0", "services": services})
        if not self.path.startswith("/rdap/domain/"):
            return self.send(404, {"errorCode": 404, "description": [CANARY]})
        name = self.path.removeprefix("/rdap/domain/")
        if scenario == "redirect":
            return self.send(302, {}, {"Location": "http://rdap-api:8080/contact"})
        if scenario == "error":
            return self.send(404, {"errorCode": 404, "title": "Not Found", "description": [CANARY]})
        if scenario == "error-object":
            return self.send(200, {"errorCode": 429, "description": [CANARY]})
        if scenario == "malformed":
            return self.send(200, b'{"registrar":')
        value = domain(name)
        if scenario == "minimal":
            value = {"objectClassName": "domain", "ldhName": name}
        if scenario == "wrong-name":
            value["ldhName"] = "different.dev"
        if scenario == "multi":
            return self.send(200, json.dumps(value).encode() + b"\n{}")
        if scenario == "bad-events":
            value["events"][0]["eventDate"] = {"value": CANARY}
        if scenario == "bad-registrar":
            value["entities"][0]["vcardArray"][1][0][3] = {"value": CANARY}
        if scenario == "bad-nameservers":
            value["nameservers"][0]["ldhName"] = [CANARY]
        if scenario in {"large", "chunked-large"}:
            value["remarks"] = ["x" * 16777217]
        if scenario == "exact":
            value["remarks"] = [""]
            value["remarks"] = ["x" * (16777216 - len(json.dumps(value).encode()))]
            assert len(json.dumps(value).encode()) == 16777216
        if scenario == "clip":
            value["nameservers"] = [{"ldhName": "ns-%04d.example.dev" % i} for i in range(1000)]
        if scenario == "controls":
            value["entities"][0]["vcardArray"][1][0][3] = "Fixture\nRegistrar\u001b[31m"
        self.send(200, value, chunked=scenario == "chunked-large")


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
