#!/bin/bash
set -euo pipefail

# Keep every executable helper byte in this declared, content-hashed script.
exec python3 -I - "$@" <<'PY'
import datetime
from decimal import Decimal
import ipaddress
import json
import math
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qsl, urlencode, urlsplit

ORIGIN = "https://incidents.betterstack.com"
CAP = 4194304
MAX_NUMBER = 9007199254740991
FREQUENCIES = (30, 45, 60, 120, 180, 300, 600, 900, 1800)
TIMEOUTS = (2, 3, 5, 10, 15, 30, 45, 60, 90, 120, 180)
RECOVERY = (0, 60, 180, 300, 900, 1800, 3600, 7200)
MONITOR_TYPES = ("status", "expected_status_code", "keyword", "keyword_absence", "ping", "tcp", "udp", "smtp", "pop", "imap", "dns", "playwright")
STATES = ("up", "down", "validating", "paused", "pending", "maintenance")
INCIDENT_STATES = ("Started", "Acknowledged", "Validating", "Resolved", "Unconfirmed")
REGIONS = ("us", "eu", "as", "au")


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def object_value(value):
    require(type(value) is dict, "Expected a Better Stack object.")
    return value


def integer(value, minimum=0, maximum=MAX_NUMBER, nullable=False):
    if value is None and nullable:
        return None
    require(type(value) is int and minimum <= value <= maximum, "Invalid Better Stack integer.")
    return value


def number(value, maximum=MAX_NUMBER):
    require(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= maximum,
            "Invalid Better Stack numeric metric.")
    return value


def identifier(value, nullable=False):
    if value is None and nullable:
        return None
    require(type(value) is str and re.fullmatch(r"[1-9][0-9]{0,19}", value), "Invalid Better Stack resource ID.")
    return value


def enum(value, allowed, nullable=False):
    if value is None and nullable:
        return None
    require(type(value) is str and value in allowed, "Unsupported Better Stack state or type.")
    return value


def boolean(value):
    require(value is None or type(value) is bool, "Invalid Better Stack boolean.")
    return value


def timestamp(value):
    if value is None:
        return None
    require(type(value) is str and len(value) <= 40 and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})", value),
        "Invalid Better Stack timestamp.")
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Failure("Invalid Better Stack calendar timestamp.") from None
    return value


def strict_json(raw):
    def pairs(entries):
        result = {}
        for key, value in entries:
            require(key not in result, "Duplicate field in Better Stack JSON.")
            result[key] = value
        return result
    def constant(_):
        raise Failure("Nonfinite Better Stack JSON value.")
    def finite_float(raw):
        value = float(raw)
        require(math.isfinite(value), "Nonfinite Better Stack JSON value.")
        return value
    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=constant, parse_float=finite_float)
        require(type(value) is dict and "errors" not in value and "error" not in value,
                "Invalid or rejected Better Stack response envelope.")
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise Failure("Invalid Better Stack JSON response.") from None


def entity(value, kind, expected_id=None):
    value = object_value(value)
    require(value.get("type") == kind, "Unexpected Better Stack JSON:API resource type.")
    rid = identifier(value.get("id"))
    require(expected_id is None or rid == expected_id, "Better Stack returned a different resource ID.")
    return rid, object_value(value.get("attributes"))


def summary(value, kind):
    rid, attrs = entity(value, kind)
    result = {"id": rid}
    if kind == "monitor":
        result.update(monitor_type=enum(attrs.get("monitor_type"), MONITOR_TYPES),
                      state=enum(attrs.get("status"), STATES, True))
        for field in ("paused", "verify_ssl", "call", "sms", "email", "push", "critical_alert"):
            result[field] = boolean(attrs.get(field))
        for field in ("check_frequency", "effective_check_frequency", "request_timeout", "confirmation_period", "recovery_period"):
            result[field] = integer(attrs.get(field), nullable=True)
        result["http_method"] = enum(attrs.get("http_method"), ("get", "head", "post", "put", "patch", "options"), True)
        regions = attrs.get("regions", [])
        require(type(regions) is list and len(regions) <= 4 and len(set(enum(x, REGIONS) for x in regions)) == len(regions),
                "Invalid Better Stack region collection.")
        result["regions"] = regions
        times = ("last_checked_at", "paused_at", "created_at", "updated_at")
    elif kind == "heartbeat":
        result["state"] = enum(attrs.get("status"), STATES, True)
        for field in ("paused", "call", "sms", "email", "push", "critical_alert"):
            result[field] = boolean(attrs.get(field))
        for field in ("period", "grace"):
            result[field] = integer(attrs.get(field), nullable=True)
        times = ("paused_at", "created_at", "updated_at")
    elif kind == "incident":
        result["state"] = enum(attrs.get("status"), INCIDENT_STATES, True)
        relationships = object_value(value.get("relationships", {}))
        for family in ("monitor", "heartbeat"):
            rel = object_value(relationships.get(family, {})).get("data")
            if rel is not None:
                rel = object_value(rel)
                require(rel.get("type") == family, "Invalid Better Stack relationship type.")
            result[family + "_id"] = identifier(rel.get("id") if rel is not None else None, True)
        times = ("started_at", "acknowledged_at", "resolved_at")
    else:
        result["aggregate_state"] = enum(attrs.get("aggregate_state"), ("operational", "degraded", "downtime", "maintenance"))
        for field in ("published", "password_enabled", "require_sso", "hide_from_search_engines"):
            # Avoid a secret-named output key, which runner redaction masks.
            result["access_protected" if field == "password_enabled" else field] = boolean(attrs.get(field))
        times = ("created_at", "updated_at")
    for field in times:
        result[field] = timestamp(attrs.get(field))
    return result


def capture(argv, config, env, seconds=17):
    deadline = time.monotonic() + seconds
    # An unlinked 0600 file prevents a non-reading child from blocking a pipe
    # write before the deadline/capture loop begins. No secret reaches argv.
    with tempfile.TemporaryFile() as private:
        private.write(config)
        private.seek(0)
        process = subprocess.Popen(argv, stdin=private, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, start_new_session=True)
    stdout, stderr = bytearray(), bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, (stdout, CAP + 4))
            selector.register(process.stderr, selectors.EVENT_READ, (stderr, 8192))
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, "Better Stack request exceeded its independent deadline.")
                for key, _ in selector.select(min(remaining, 0.2)):
                    target, limit = key.data
                    chunk = os.read(key.fileobj.fileno(), min(65536, limit + 1 - len(target)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        target.extend(chunk)
                        require(len(target) <= limit, "Better Stack response exceeded its independent byte budget.")
        process.wait(timeout=max(0.01, deadline - time.monotonic()))
        return process.returncode, bytes(stdout)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        process.stdout.close()
        process.stderr.close()


def request(method, path, query=None, body=None, expected=(200,)):
    access = os.environ.get("BETTERSTACK_API_TOKEN", "")
    require(len(access) <= 4096 and re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", access),
            "A valid Better Stack API credential is required in the inherited environment.")
    config = 'header = "Authorization: Bearer ' + access + '"\n'
    if body is not None:
        config += 'header = "Content-Type: application/json"\ndata-binary = ' + json.dumps(json.dumps(body, separators=(",", ":"))) + "\n"
    url = ORIGIN + path + ("?" + urlencode(query) if query else "")
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CURL_CA_BUNDLE")}
    argv = ["curl", "-q", "--config", "-", "--fail-with-body", "--silent", "--show-error", "--globoff",
            "--proto", "=https", "--connect-timeout", "5", "--max-time", "15", "--max-redirs", "0",
            "--max-filesize", str(CAP), "--proxy", "", "--request", method, "--url", url,
            "--write-out", "\n%{http_code}"]
    status, raw = capture(argv, config.encode(), env)
    payload, separator, http = raw.rpartition(b"\n")
    require(separator and re.fullmatch(b"[0-9]{3}", http), "Could not capture the Better Stack HTTP status.")
    code = int(http)
    if status or code not in expected:
        if code == 409:
            raise Failure("Better Stack HTTP 409 conflict; inspect incident_details before claiming the requested state.")
        if status == 63:
            raise Failure("Better Stack response exceeds the 4 MiB byte budget.")
        if code >= 300:
            raise Failure(f"Better Stack API request failed with HTTP {code}; provider body omitted.")
        raise Failure("Better Stack transport failed; check TLS, reachability and request deadline.")
    require(len(payload) <= CAP, "Better Stack response exceeds the 4 MiB byte budget.")
    if code == 204:
        require(not payload, "Expected an empty Better Stack deletion receipt.")
        return None
    return strict_json(payload)


def page_result(envelope, kind, path, query):
    rows = envelope.get("data")
    require(type(rows) is list and len(rows) <= query["per_page"], "Invalid or oversized Better Stack collection.")
    pagination = object_value(envelope.get("pagination"))
    require("next" in pagination, "Missing Better Stack pagination continuation.")
    following = pagination["next"]
    next_page = None
    if following is not None:
        require(type(following) is str and len(following) <= 2048, "Unsupported Better Stack pagination URL.")
        parsed = urlsplit(following)
        require(parsed.scheme == "https" and parsed.netloc == "incidents.betterstack.com" and parsed.path == path and not parsed.fragment,
                "Unsafe Better Stack pagination origin or path.")
        pairs = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
        values = dict(pairs)
        require(len(values) == len(pairs) and set(values) == set(query), "Unsupported Better Stack pagination selectors.")
        require(re.fullmatch(r"[1-9][0-9]{0,5}", values.get("page", "")), "Unsupported Better Stack next page.")
        next_page = int(values["page"])
        require(query["page"] < next_page <= 100000 and all(str(v) == values[k] for k, v in query.items() if k != "page"),
                "Unsupported Better Stack pagination progress or selectors.")
    return {"items": [summary(row, kind) for row in rows], "returned_count": len(rows),
            "more_available": next_page is not None, "next_page": next_page}


def public_url(value):
    require(type(value) is str and 1 <= len(value) <= 2048 and all(33 <= ord(c) <= 126 for c in value),
            "A bounded ASCII public monitor URL is required.")
    parsed = urlsplit(value)
    require(parsed.scheme in ("http", "https") and parsed.hostname and parsed.username is None and parsed.password is None
            and not parsed.query and not parsed.fragment and "?" not in value and "#" not in value and "\\" not in value,
            "Monitor URL must be HTTP(S), without credentials, query or fragment.")
    require(parsed.port is None or 1 <= parsed.port <= 65535, "Invalid monitor URL port.")
    host = parsed.hostname
    try:
        address = ipaddress.ip_address(host)
        require(address.is_global, "Monitor URL must use a public host.")
    except ValueError:
        labels = host.split(".")
        require(len(host) <= 253 and len(labels) >= 2 and not host.endswith((".localhost", ".local", ".internal", ".test", ".invalid"))
                and not labels[-1].isdigit() and all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in labels),
                "Monitor URL must use a public DNS name or globally routable IP literal.")
    return value


def supplied_integer(raw, allowed=None, minimum=0, maximum=MAX_NUMBER):
    require(re.fullmatch(r"[0-9]{1,16}", raw), "Invalid bounded numeric argument.")
    value = integer(int(raw), minimum, maximum)
    require(allowed is None or value in allowed, "Unsupported Better Stack numeric setting.")
    return value


def main(argv):
    mode, *args = argv
    families = {"monitors": ("monitor", "/api/v2/monitors"), "heartbeats": ("heartbeat", "/api/v2/heartbeats"),
                "incidents": ("incident", "/api/v3/incidents"), "status_pages": ("status_page", "/api/v2/status-pages")}
    if mode.endswith("_list"):
        kind, path = families[mode[:-5]]
        query = {"page": supplied_integer(args[0], minimum=1, maximum=100000),
                 "per_page": supplied_integer(args[1], minimum=1, maximum=6)}
        if mode == "incidents_list":
            for key, value in zip(("monitor_id", "heartbeat_id", "resolved", "acknowledged"), args[2:]):
                if value:
                    query[key] = identifier(value) if key.endswith("_id") else enum(value, ("true", "false"))
        return page_result(request("GET", path, query), kind, path, query)
    if mode == "monitor_create":
        url, method, frequency, timeout, confirmation, recovery, team = args
        frequency = supplied_integer(frequency, FREQUENCIES)
        timeout = supplied_integer(timeout, TIMEOUTS)
        require(timeout <= frequency, "Monitor timeout cannot exceed its check frequency.")
        body = {"url": public_url(url), "monitor_type": "status", "http_method": enum(method, ("GET", "HEAD")),
                "verify_ssl": True, "check_frequency": frequency, "request_timeout": timeout,
                "confirmation_period": supplied_integer(confirmation, maximum=86400),
                "recovery_period": supplied_integer(recovery, RECOVERY)}
        require(len(team) <= 128 and all(ord(c) >= 32 and ord(c) != 127 for c in team), "Invalid bounded team selector.")
        if team:
            body["team_name"] = team
        value = request("POST", "/api/v2/monitors", body=body, expected=(201,))["data"]
        rid, attrs = entity(value, "monitor")
        require(all(attrs.get(k) == (v.lower() if k == "http_method" else v) for k, v in body.items()),
                "Better Stack did not confirm the requested monitor configuration.")
        return summary(value, "monitor")
    rid = identifier(args[0])
    family = "monitors" if mode.startswith("monitor_") else "incidents" if mode.startswith("incident_") else "heartbeats" if mode.startswith("heartbeat_") else "status_pages"
    kind, path = families[family]
    path += "/" + rid
    if mode == "monitor_delete":
        request("DELETE", path, expected=(204,))
        return {"id": rid, "deleted": True}
    if mode in ("incident_acknowledge", "incident_resolve"):
        field, verb = ("acknowledged", "acknowledge") if mode.endswith("acknowledge") else ("resolved", "resolve")
        value = request("POST", path + "/" + verb, body={field + "_by": "Emisar"})["data"]
        entity(value, kind, rid)
        result = summary(value, kind)
        require(result[field + "_at"] is not None, "Better Stack did not confirm the requested incident lifecycle change.")
        return result
    if mode in ("monitor_update", "monitor_pause", "monitor_resume", "heartbeat_update"):
        body = {}
        if mode in ("monitor_pause", "monitor_resume"):
            body = {"paused": mode == "monitor_pause"}
        elif mode == "monitor_update":
            for key, raw, allowed, maximum in zip(("check_frequency", "request_timeout", "confirmation_period", "recovery_period"), args[1:],
                                                 (FREQUENCIES, TIMEOUTS, None, RECOVERY), (1800, 180, 86400, 7200)):
                if raw != "-1":
                    body[key] = supplied_integer(raw, allowed, maximum=maximum)
            require(body, "Select at least one monitor timing setting.")
            current = request("GET", path)["data"]
            _, before = entity(current, kind, rid)
            require(before.get("monitor_type") in MONITOR_TYPES[:4], "Monitor timing updates support HTTP checks only; server and Playwright timeout units differ.")
            frequency = body.get("check_frequency", before.get("check_frequency"))
            timeout = body.get("request_timeout", before.get("request_timeout"))
            require(type(frequency) is int and type(timeout) is int and timeout <= frequency,
                    "Monitor timeout cannot exceed its check frequency.")
        else:
            for key, raw, minimum in zip(("period", "grace"), args[1:3], (30, 0)):
                if raw != "-1":
                    body[key] = supplied_integer(raw, minimum=minimum, maximum=31535999)
            if args[3]:
                body["paused"] = enum(args[3], ("true", "false")) == "true"
            require(body, "Select at least one heartbeat setting.")
        value = request("PATCH", path, body=body)["data"]
        _, after = entity(value, kind, rid)
        require(all(type(after.get(k)) is type(v) and after[k] == v for k, v in body.items()),
                "Better Stack did not confirm the requested settings.")
        return summary(value, kind)
    if mode == "monitor_availability":
        try:
            require(all(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", x) for x in args[1:]), "Use YYYY-MM-DD dates.")
            start, end = [datetime.date.fromisoformat(x) for x in args[1:]]
            require(0 <= (end - start).days <= 30, "Availability dates must span at most 31 inclusive calendar days.")
        except ValueError:
            raise Failure("Invalid availability calendar date.") from None
        value = request("GET", path + "/sla", {"from": args[1], "to": args[2]})["data"]
        _, attrs = entity(value, "monitor_sla", rid)
        return {"id": rid, "from": args[1], "to": args[2], "availability": number(attrs.get("availability"), 100),
                **{key: integer(attrs.get(key)) for key in ("total_downtime", "number_of_incidents", "longest_incident", "average_incident")}}
    if mode == "monitor_response_times":
        value = request("GET", path + "/response-times")["data"]
        _, attrs = entity(value, "monitor_response_times", rid)
        regions = attrs.get("regions")
        require(type(regions) is list and len(regions) <= 4, "Invalid Better Stack response-time regions.")
        result, seen = [], set()
        for row in regions:
            row = object_value(row)
            region = enum(row.get("region"), REGIONS)
            require(region not in seen, "Duplicate Better Stack metric region.")
            seen.add(region)
            samples = row.get("response_times")
            require(type(samples) is list, "Missing Better Stack response-time samples.")
            values, latest = [], None
            for sample in samples:
                sample = object_value(sample)
                at = timestamp(sample.get("at"))
                require(at is not None, "Missing Better Stack metric timestamp.")
                measured = number(sample.get("response_time"))
                values.append(measured)
                instant = datetime.datetime.fromisoformat(at.replace("Z", "+00:00"))
                if latest is None or instant > latest[0]:
                    latest = (instant, at, measured)
            result.append({"region": region, "sample_count": len(values), "minimum_seconds": min(values) if values else None,
                           # Average decimal API representations before the
                           # single final conversion used by JSON output.
                           "mean_seconds": float(sum(Decimal(str(v)) for v in values) / len(values)) if values else None,
                           "maximum_seconds": max(values) if values else None,
                           "latest_at": latest[1] if latest else None, "latest_seconds": latest[2] if latest else None})
        return {"id": rid, "window_hours": 24, "regions": result}
    require(mode in ("monitor_details", "incident_details", "heartbeat_details", "status_page_details"), "Unsupported Better Stack action.")
    value = request("GET", path)["data"]
    entity(value, kind, rid)
    return summary(value, kind)


if __name__ == "__main__":
    try:
        result = main(sys.argv[1:])
        encoded = json.dumps(result, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
        require(len(encoded.encode()) <= 8192, "Better Stack result exceeds the structured byte budget.")
        print(encoded)
    except (Failure, OSError, ValueError, KeyError, IndexError, TypeError, OverflowError, subprocess.SubprocessError) as exc:
        # Only authored diagnostics cross the boundary; never raw URLs,
        # provider bodies, child stderr or exception text.
        print(str(exc) if isinstance(exc, Failure) else "Better Stack action failed validation or bounded client execution.", file=sys.stderr)
        sys.exit(1)
PY
