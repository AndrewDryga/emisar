"""Independent request/state postconditions; prints no hidden fixture values."""
import importlib.util
import json
from pathlib import Path
import ssl
import sys
from urllib.request import Request, urlopen

BASE = "https://betterstack-api"
CONTEXT = ssl.create_default_context(cafile="/packs/betterstack/test/fixtures/server.crt")
spec = importlib.util.spec_from_file_location("contract_server", Path(__file__).parent / "fixtures/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def fetch(path, data=None):
    request = Request(BASE + path, data=json.dumps(data).encode() if data is not None else None,
                      headers={"Content-Type": "application/json"})
    with urlopen(request, context=CONTEXT, timeout=5) as response:
        return json.load(response)


def probe(mode):
    snapshot = fetch("/__fixture/state")
    state, requests = snapshot["state"], snapshot["requests"]
    if mode == "no-provider-request":
        assert requests == [], "Invalid input reached provider request dispatch"
    elif mode == "curl-audit":
        value = json.loads(Path("/tmp/betterstack-curl-audit.json").read_text())
        assert all(value.values())
    else:
        last = requests[-1]
        family = "monitors" if mode.startswith("monitor_") else "heartbeats" if mode.startswith("heartbeat_") else "incidents"
        identifier = {"monitors": "101", "heartbeats": "201", "incidents": "301"}[family]
        if mode == "monitor_create":
            value = state[family]["102"]["attributes"]
            body = last["body"]
            assert last["method"] == "POST" and last["path"] == "/api/v2/monitors"
            assert body["url"] == "https://example.com/health" and body["http_method"] == "HEAD"
            assert body["verify_ssl"] is True and body["monitor_type"] == "status"
            assert body["team_name"] == 'Team "quoted" \\ literal'
            assert set(body) == {"url", "http_method", "verify_ssl", "monitor_type", "check_frequency", "request_timeout", "confirmation_period", "recovery_period", "team_name"}
            assert value["url"] == body["url"]
        elif mode == "url-literal":
            assert last["body"]["url"] == "https://example.com/$(touch%20/tmp/pwned)"
            assert not Path("/tmp/pwned").exists()
        elif mode == "monitor_delete":
            assert identifier not in state[family] and last["method"] == "DELETE" and last["body"] is None
        elif mode == "monitor_update":
            assert len(requests) == 2 and requests[0]["method"] == "GET"
            assert last["body"] == {"check_frequency": 120, "request_timeout": 30, "confirmation_period": 180, "recovery_period": 300}
            assert state[family][identifier]["attributes"]["confirmation_period"] == 180
        elif mode in ("monitor_pause", "monitor_resume"):
            expected = mode == "monitor_pause"
            assert last["body"] == {"paused": expected}
            assert state[family][identifier]["attributes"]["paused"] is expected
        elif mode == "heartbeat_update":
            assert last["body"] == {"period": 3600, "grace": 600, "paused": True}
            assert all(state[family][identifier]["attributes"][k] == v for k, v in last["body"].items())
        elif mode in ("incident_acknowledge", "incident_resolve"):
            field = "acknowledged" if mode.endswith("acknowledge") else "resolved"
            assert last["body"] == {field + "_by": "Emisar"}
            assert state[family][identifier]["attributes"][field + "_at"] is not None
            assert last["path"] == "/api/v3/incidents/301/" + ("acknowledge" if field == "acknowledged" else "resolve")
        elif mode == "incidents-filtered":
            assert last["query"] == {"page": ["1"], "per_page": ["6"], "monitor_id": ["101"], "heartbeat_id": ["201"], "resolved": ["false"], "acknowledged": ["true"]}
        elif mode == "pagination":
            assert last["query"] == {"page": ["2"], "per_page": ["6"]}
        else:
            raise AssertionError("Unknown postcondition mode")
        if mode in ("monitor_update", "monitor_pause", "monitor_resume", "heartbeat_update"):
            before = server.initial()[family][identifier]["attributes"]
            after = state[family][identifier]["attributes"]
            changed = set(last["body"]) | {"status", "paused_at"}
            assert {k: v for k, v in before.items() if k not in changed} == {k: v for k, v in after.items() if k not in changed}, "An unrelated or hidden setting changed"
    print(json.dumps({"postcondition": True}))


if sys.argv[1] == "control":
    fetch("/__fixture/control", {"scenario": sys.argv[2]})
    print("Fixture scenario selected")
elif sys.argv[1] == "probe":
    probe(sys.argv[2])
else:
    raise AssertionError("Unknown fixture command")
