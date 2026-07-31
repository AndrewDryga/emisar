#!/usr/bin/env python3
import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


API_KEY = "packtest-canary-bunny-key-c8e41"


def initial_zone():
    return {
        "Id": 123456,
        "Name": "fixture-cdn",
        "OriginUrl": "https://origin-user:packtest-canary-origin-password@origin.example.test/assets",
        "OriginHostHeader": "origin.example.test",
        "VerifyOriginSSL": True,
        "Enabled": True,
        "Suspended": False,
        "Type": 0,
        "MonthlyBandwidthUsed": 987654321,
        "MonthlyCharges": 12.34,
        "CacheControlMaxAgeOverride": 3600,
        "CacheControlPublicMaxAgeOverride": 600,
        "EnableCacheSlice": True,
        "EnableSmartCache": False,
        "EnableOriginShield": True,
        "OriginShieldZoneCode": "DE",
        "EnableLogging": True,
        "LoggingIPAnonymizationEnabled": True,
        "LogAnonymizationType": 0,
        "LogFormat": 1,
        "AllowedReferrers": ["old.example.com"],
        "BlockedReferrers": ["blocked.example.com"],
        "BlockedIps": ["192.0.2.10"],
        "ZoneSecurityKey": "packtest-canary-zone-security-key-2a9c",
        "AWSSigningKey": "packtest-canary-aws-key-51fd",
        "AWSSigningSecret": "packtest-canary-aws-secret-775e",
        "LogForwardingToken": "packtest-canary-forward-token-9bc2",
        "Hostnames": [
            {
                "Id": 1,
                "Value": "fixture-cdn.b-cdn.net",
                "ForceSSL": True,
                "IsSystemHostname": True,
                "HasCertificate": True,
                "Certificate": "packtest-canary-certificate-3cd1",
                "CertificateKey": "packtest-canary-private-key-88ef",
            },
            {
                "Id": 2,
                "Value": "cdn.example.test",
                "ForceSSL": False,
                "IsSystemHostname": False,
                "HasCertificate": True,
                "Certificate": "packtest-canary-certificate-3cd1",
                "CertificateKey": "packtest-canary-private-key-88ef",
            },
        ],
    }


STATE = {
    "zones": {123456: initial_zone()},
    "deleted": [],
    "purges": [],
    "reads": [],
    "events": [],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def send_json(self, value, status=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_empty(self, status=204):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def authorized(self):
        if self.headers.get("AccessKey") == API_KEY:
            return True
        self.send_json({"ErrorKey": "unauthorized"}, 401)
        return False

    def zone(self, zone_id):
        zone = STATE["zones"].get(zone_id)
        if zone is None:
            self.send_json({"ErrorKey": "pull_zone_not_found"}, 404)
        return zone

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self.send_json({"ok": True})
            return
        if path == "/probe/state":
            self.send_json(STATE)
            return
        if path.startswith("/probe/zones/"):
            zone_id = int(path.rsplit("/", 1)[1])
            self.send_json(STATE["zones"].get(zone_id, {"deleted": True, "Id": zone_id}))
            return
        if not self.authorized():
            return

        if path == "/core/pullzone":
            items = list(STATE["zones"].values())
            search = query.get("search", [""])[0].lower()
            if search:
                items = [zone for zone in items if search in zone["Name"].lower()]
            self.send_json({"Items": items, "CurrentPage": 1, "TotalItems": len(items), "HasMoreItems": False})
            return
        if path.startswith("/core/pullzone/") and path.count("/") == 3:
            zone = self.zone(int(path.rsplit("/", 1)[1]))
            if zone is not None:
                self.send_json(zone)
            return
        if path == "/core/region":
            self.send_json([{"Id": 1, "Name": "Frankfurt", "ZoneCode": "DE"}, {"Id": 2, "Name": "Washington", "ZoneCode": "WA"}])
            return
        if path == "/core/statistics":
            self.send_json({
                "TotalBandwidthUsed": 400000000000,
                "TotalOriginTraffic": 5000000000,
                "AverageOriginResponseTime": 41,
                "TotalRequestsServed": 53000000,
                "CacheHitRate": 91.2,
                "BandwidthUsedChart": {"2026-07-31T12:00:00Z": 1200},
                "Error5xxChart": {"2026-07-31T12:00:00Z": 3},
            })
            return
        if path.endswith("/optimizer/statistics"):
            self.send_json({"TotalRequestsOptimized": 1200, "TotalTrafficSaved": 4096000, "AverageCompressionRatio": 0.71})
            return
        if path.endswith("/originshield/queuestatistics"):
            self.send_json({"ConcurrentRequestsChart": {"2026-07-31T12:00:00Z": 7}, "QueuedRequestsChart": {"2026-07-31T12:00:00Z": 2}})
            return
        if path.endswith("/safehop/statistics"):
            self.send_json({"TotalRequestsRetried": 12, "TotalRequestsSaved": 9})
            return
        if path == "/core/billing":
            self.send_json({
                "Balance": 95.50,
                "AvailableBalance": 100.25,
                "ThisMonthCharges": 44.75,
                "MonthlyBandwidthUsed": 400000000000,
                "MonthlyChargesEUTraffic": 30.0,
                "MonthlyChargesASIATraffic": 5.0,
                "MonthlyChargesAFTraffic": 1.0,
                "MonthlyChargesSATraffic": 2.0,
                "MonthlyChargesOptimizer": 3.0,
                "MonthlyChargesStorage": 2.0,
                "MonthlyChargesShield": 1.0,
                "MonthlyChargesWebSockets": 0.25,
                "AutomaticPaymentIdentifier": "packtest-canary-payment-id-a810",
                "SavedPaymentMethods": [{"Token": "packtest-canary-payment-token-883a"}],
            })
            return
        if path == "/core/billing/summary":
            self.send_json([{"PullZoneId": 123456, "MonthlyUsage": 12.34, "MonthlyBandwidthUsed": 987654321}])
            return
        if path == "/logging/pullzones/123456/logs":
            STATE["reads"].append("logging_v2")
            self.send_json({
                "data": [
                    {
                        "timestamp": "2026-07-31T12:00:00Z",
                        "pullZoneId": 123456,
                        "requestId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "cacheStatus": "STALE",
                        "statusCode": 206,
                        "bytesSent": 4000,
                        "remoteIp": "192.0.2.0",
                        "path": "/video/intro.mp4?token=packtest-canary-query-token-6a21",
                        "url": "https://cdn.example.test/video/intro.mp4?token=packtest-canary-query-token-6a21",
                        "userAgent": "fixture-player/1.0",
                        "referer": "https://app.example.test/champions?session=packtest-canary-referrer-9b71",
                        "authorizationHeader": "Bearer packtest-canary-request-auth-0ee3",
                    },
                    {
                        "timestamp": "2026-07-31T12:01:00Z",
                        "pullZoneId": 123456,
                        "requestId": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "cacheStatus": "STALE",
                        "statusCode": 206,
                        "bytesSent": 6000,
                        "remoteIp": "192.0.2.0",
                        "path": "/video/intro.mp4?range=2",
                        "url": "https://cdn.example.test/video/intro.mp4?range=2",
                        "userAgent": "fixture-player/1.0",
                        "referer": None,
                    },
                    {
                        "timestamp": "2026-07-31T12:02:00Z",
                        "pullZoneId": 123456,
                        "requestId": "cccccccccccccccccccccccccccccccc",
                        "cacheStatus": "HIT",
                        "statusCode": 200,
                        "bytesSent": 1000,
                        "remoteIp": "198.51.100.0",
                        "path": "/images/logo.webp",
                        "url": "https://cdn.example.test/images/logo.webp",
                        "userAgent": "fixture-browser/1.0",
                        "referer": None,
                    },
                ],
                "pagination": {"offset": 0, "limit": 100, "returned": 3, "hasMore": False},
                "query": {"pullZoneId": 123456, "order": "desc"},
            })
            return
        if path == "/origin/123456/07-31-2026":
            STATE["reads"].append("origin_errors")
            detail = {
                "RequestUrl": "/apikey?token=packtest-canary-origin-query-4c31",
                "PullZoneId": 123456,
                "Message": "Origin DNS lookup failed",
                "ErrorCode": "dns_lookup",
                "StatusCode": 502,
                "Credential": "packtest-canary-origin-log-extra-372a",
            }
            self.send_json({"logs": [{"logId": "fixture-log-1", "timestamp": 1785499200000, "log": json.dumps(detail), "labels": {"ErrorCode": "dns_lookup", "StatusCode": "502", "ServerZone": "DE"}}]})
            return

        self.send_json({"ErrorKey": "not_found"}, 404)

    def do_POST(self):
        self.mutate()

    def do_DELETE(self):
        self.mutate()

    def mutate(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        if not self.authorized():
            return

        if self.command == "POST" and path == "/core/pullzone":
            body = self.read_json()
            zone = initial_zone()
            zone.update({
                "Id": 654321,
                "Name": body["Name"],
                "OriginUrl": body.get("OriginUrl"),
                "Type": body.get("Type", 0),
                "EnableLogging": body.get("EnableLogging", True),
                "EnableCacheSlice": body.get("EnableCacheSlice", False),
                "Hostnames": [{"Id": 3, "Value": f'{body["Name"]}.b-cdn.net', "ForceSSL": True, "IsSystemHostname": True}],
            })
            STATE["zones"][654321] = zone
            self.send_json(zone, 201)
            return
        if self.command == "POST" and path == "/core/purge":
            STATE["purges"].append({"scope": "url", "url": query.get("url", [""])[0]})
            self.send_empty(200)
            return

        parts = path.strip("/").split("/")
        if len(parts) >= 3 and parts[0:2] == ["core", "pullzone"]:
            zone_id = int(parts[2])
            zone = self.zone(zone_id)
            if zone is None:
                return
            if len(parts) == 3:
                if self.command == "DELETE":
                    del STATE["zones"][zone_id]
                    STATE["deleted"].append(zone_id)
                    self.send_empty()
                    return
                zone.update(self.read_json())
                self.send_json(zone)
                return

            resource = parts[3]
            body = self.read_json()
            if resource == "addHostname":
                zone["Hostnames"].append({"Id": 99, "Value": body["Hostname"], "ForceSSL": False, "IsSystemHostname": False})
            elif resource == "removeHostname":
                zone["Hostnames"] = [item for item in zone["Hostnames"] if item["Value"] != body["Hostname"]]
                STATE["events"].append(f'removed_hostname:{body["Hostname"]}')
            elif resource == "setForceSSL":
                for item in zone["Hostnames"]:
                    if item["Value"] == body["Hostname"]:
                        item["ForceSSL"] = body["ForceSSL"]
            elif resource == "addAllowedReferrer":
                zone["AllowedReferrers"].append(body["Hostname"])
            elif resource == "removeAllowedReferrer":
                zone["AllowedReferrers"] = [value for value in zone["AllowedReferrers"] if value != body["Hostname"]]
                STATE["events"].append(f'removed_allowed_referrer:{body["Hostname"]}')
            elif resource == "addBlockedReferrer":
                zone["BlockedReferrers"].append(body["Hostname"])
            elif resource == "removeBlockedReferrer":
                zone["BlockedReferrers"] = [value for value in zone["BlockedReferrers"] if value != body["Hostname"]]
                STATE["events"].append(f'removed_blocked_referrer:{body["Hostname"]}')
            elif resource == "addBlockedIp":
                zone["BlockedIps"].append(body["BlockedIp"])
            elif resource == "removeBlockedIp":
                zone["BlockedIps"] = [value for value in zone["BlockedIps"] if value != body["BlockedIp"]]
                STATE["events"].append(f'removed_blocked_ip:{body["BlockedIp"]}')
            elif resource == "purgeCache":
                STATE["purges"].append({"scope": "tag" if body.get("CacheTag") else "pull_zone", "pull_zone_id": zone_id, "cache_tag": body.get("CacheTag", "")})
            else:
                self.send_json({"ErrorKey": "not_found"}, 404)
                return
            self.send_empty()
            return

        self.send_json({"ErrorKey": "not_found"}, 404)


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
