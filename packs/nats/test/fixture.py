"""Seed/probe a real isolated NATS cluster; never substitute API responses."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

STREAM = "EMISAR_TEST"
CONSUMER = "worker"
AGE = 9223372036000000000
PRIVATE = "packtest-canary-nats-private-metadata-5172"
DESCRIPTION = "packtest-canary-nats-private-description-44a"
PAYLOAD = "packtest-canary-nats-message-payload-896f"
STATE = Path("/tmp/nats-fixture-state.json")


def request(role, rpc_subject, body, inbox=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("NATS_")}
    env.update(NATS_URL="tls://nats-1:4222", NATS_CA="/packs/nats/test/fixtures/ca.pem",
               NATS_USER="emisar_" + role, NATS_PASSWORD="packtest-canary-nats-" + role + "-password-2b67")
    argv = ["nats", "--no-context", "--inbox-prefix", inbox or "_INBOX.emisar." + role,
            "--timeout", "3s", "request", "--raw", "--no-templates", "--force-stdin", rpc_subject]
    result = subprocess.run(argv, input=json.dumps(body).encode(), capture_output=True, env=env, timeout=6)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Native fixture request failed or returned empty data")
    value = json.loads(result.stdout)
    if value.get("error"):
        raise RuntimeError("Native fixture provider rejected the request")
    return value


def until(rpc_subject, check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            value = request("read", rpc_subject, {})
            if check(value):
                return value
        except RuntimeError:
            pass
        time.sleep(0.25)
    raise RuntimeError("Real NATS fixture did not reach its expected state")


def caught_up(value):
    peers = value.get("cluster", {}).get("replicas", [])
    return bool(value.get("cluster", {}).get("leader")) and len(peers) == 2 and all(p.get("current") for p in peers)


def digest(cfg, excluded):
    return hashlib.sha256(json.dumps({k: v for k, v in cfg.items() if k not in excluded}, sort_keys=True).encode()).hexdigest()


def seed(mode):
    until("$JS.API.INFO", lambda d: "limits" in d)
    if mode == "empty":
        return
    if mode == "names":
        for n in range(13):
            name = f"S{n:02d}" + "x" * 252
            request("seed", "$JS.API.STREAM.CREATE." + name,
                    {"name": name, "subjects": ["names." + str(n)], "storage": "file", "max_bytes": 4096, "max_msgs": 1, "num_replicas": 1})
        return
    cfg = {"name": STREAM, "subjects": ["emisar.test"], "storage": "file", "retention": "limits",
           "num_replicas": 3, "max_bytes": 1048576, "max_msgs": 100, "max_age": AGE,
           "description": DESCRIPTION, "metadata": {"private": PRIVATE, "literal_template": "{{Count}}"}}
    if mode == "interest":
        cfg["retention"] = "interest"
    request("seed", "$JS.API.STREAM.CREATE." + STREAM, cfg)
    stream = until("$JS.API.STREAM.INFO." + STREAM, caught_up)
    ccfg = {"name": CONSUMER, "durable_name": CONSUMER, "filter_subject": "emisar.test", "ack_policy": "explicit",
            "deliver_policy": "all", "ack_wait": 30000000000, "max_ack_pending": 1000, "max_deliver": -1,
            "num_replicas": 3, "description": DESCRIPTION, "metadata": {"private": PRIVATE, "literal_template": "{{Count}}"}}
    request("seed", "$JS.API.CONSUMER.CREATE." + STREAM + "." + CONSUMER, {"stream_name": STREAM, "config": ccfg, "action": "create"})
    consumer = until("$JS.API.CONSUMER.INFO." + STREAM + "." + CONSUMER, caught_up)
    for n in range(3):
        # A test-only real application publication obtains the native stream
        # PubAck. No product action publishes or reads application payloads.
        ack = request("seed", "emisar.test", PAYLOAD + str(n))
        assert ack["seq"] == n + 1
    until("$JS.API.STREAM.INFO." + STREAM, lambda d: d["state"]["messages"] == 3)
    STATE.write_text(json.dumps({"stream_leader": stream["cluster"]["leader"], "consumer_leader": consumer["cluster"]["leader"],
                                "stream_other": digest(stream["config"], {"max_bytes", "max_msgs", "max_age"}),
                                "consumer_other": digest(consumer["config"], {"max_ack_pending", "max_deliver", "ack_wait"})}))
    if mode == "paused":
        until_time = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=300)).isoformat().replace("+00:00", "Z")
        request("seed", "$JS.API.CONSUMER.PAUSE." + STREAM + "." + CONSUMER, {"pause_until": until_time})
    if mode == "consumer_names":
        for n in range(13):
            name = f"C{n:02d}" + "x" * 252
            request("seed", "$JS.API.CONSUMER.CREATE." + STREAM + "." + name,
                    {"stream_name": STREAM, "config": {"name": name, "durable_name": name, "ack_policy": "explicit", "num_replicas": 1}, "action": "create"})
    if mode == "worst":
        filters = ["worst" + str(n) + "." + "\u2028" * 300 for n in range(4)]
        request("seed", "$JS.API.STREAM.CREATE.WORST", {"name": "WORST", "subjects": filters, "storage": "file", "num_replicas": 3,
                                                        "max_bytes": 4096, "max_msgs": 1, "description": DESCRIPTION, "metadata": {"private": PRIVATE}})
        until("$JS.API.STREAM.INFO.WORST", caught_up)
        request("seed", "$JS.API.CONSUMER.CREATE.WORST.worst_worker", {"stream_name": "WORST", "config": {"name": "worst_worker", "durable_name": "worst_worker", "filter_subjects": filters, "ack_policy": "explicit", "num_replicas": 3}, "action": "create"})
        until("$JS.API.CONSUMER.INFO.WORST.worst_worker", caught_up)


def probe(kind, args):
    before = json.loads(STATE.read_text()) if STATE.exists() else {}
    if kind in ("stream", "stream_leader"):
        stream = args[0] if args else STREAM
        if kind == "stream_leader":
            d = until("$JS.API.STREAM.INFO." + stream, lambda v: caught_up(v) and v["cluster"]["leader"] != before["stream_leader"])
        else:
            d = request("read", "$JS.API.STREAM.INFO." + stream, {})
        cfg, state = d["config"], d["state"]
        return {"name": cfg["name"], "messages": str(state.get("messages", 0)), "first_sequence": str(state.get("first_seq", 0)),
                "max_bytes": str(cfg["max_bytes"]), "max_messages": str(cfg["max_msgs"]), "max_age_ns": str(cfg.get("max_age", 0)),
                "other_configuration_preserved": digest(cfg, {"max_bytes", "max_msgs", "max_age"}) == before.get("stream_other"),
                "metadata_literal_preserved": cfg.get("metadata", {}).get("literal_template") == "{{Count}}",
                "metadata_private_preserved": cfg.get("metadata", {}).get("private") == PRIVATE,
                "leader_changed": d.get("cluster", {}).get("leader") != before.get("stream_leader"), "caught_up": caught_up(d)}
    if kind in ("consumer", "consumer_leader"):
        consumer = args[0] if args else CONSUMER
        rpc = "$JS.API.CONSUMER.INFO." + STREAM + "." + consumer
        if kind == "consumer_leader":
            d = until(rpc, lambda v: caught_up(v) and v["cluster"]["leader"] != before["consumer_leader"])
        else:
            d = request("read", rpc, {})
        cfg = d["config"]
        return {"name": d["name"], "paused": d.get("paused", False), "ack_wait_ns": str(cfg.get("ack_wait", 0)),
                "max_ack_pending": str(cfg.get("max_ack_pending", 0)), "max_deliver": str(cfg.get("max_deliver", -1)),
                "filter_subject": cfg.get("filter_subject", ""), "pull": not bool(cfg.get("deliver_subject")),
                "other_configuration_preserved": digest(cfg, {"max_ack_pending", "max_deliver", "ack_wait"}) == before.get("consumer_other"),
                "metadata_literal_preserved": cfg.get("metadata", {}).get("literal_template") == "{{Count}}",
                "metadata_private_preserved": cfg.get("metadata", {}).get("private") == PRIVATE,
                "leader_changed": d.get("cluster", {}).get("leader") != before.get("consumer_leader"), "caught_up": caught_up(d)}
    if kind in ("streams", "consumers"):
        rpc = "$JS.API.STREAM.NAMES" if kind == "streams" else "$JS.API.CONSUMER.NAMES." + STREAM
        d = request("read", rpc, {})
        names = d.get(kind)
        if names is None:
            names = []
        assert isinstance(names, list)
        return {"names": names, "test_stream_present": STREAM in names, "new_stream_present": "NEW_STREAM" in names,
                "worker_present": CONSUMER in names}
    if kind in ("reader_denial", "inbox_denial", "admin_application_denial"):
        if kind == "reader_denial":
            role, rpc, body, inbox = "read", "$JS.API.STREAM.CREATE.FORBIDDEN", {"name": "FORBIDDEN", "subjects": ["forbidden"]}, None
        elif kind == "inbox_denial":
            role, rpc, body, inbox = "read", "$JS.API.INFO", {}, "_INBOX.emisar.other"
        else:
            role, rpc, body, inbox = "admin", "emisar.test", "forbidden-publication", None
        try:
            request(role, rpc, body, inbox)
        except RuntimeError:
            denied = True
        else:
            raise AssertionError("Restricted fixture identity unexpectedly succeeded")
        names = request("read", "$JS.API.STREAM.NAMES", {}).get("streams", [])
        info = request("read", "$JS.API.STREAM.INFO." + STREAM, {})
        return {"denied": denied, "forbidden_absent": "FORBIDDEN" not in names, "messages": str(info["state"]["messages"])}
    if kind == "admin_indirect_authority":
        # A raw credential holder has broader config-API authority than the
        # signed pull-only action. Capture one synthetic fixture payload
        # privately and report booleans only, never application content.
        inbox = "_INBOX.emisar.admin.delivery"
        env = {k: v for k, v in os.environ.items() if not k.startswith("NATS_")}
        env.update(NATS_URL="tls://nats-1:4222", NATS_CA="/packs/nats/test/fixtures/ca.pem",
                   NATS_USER="emisar_admin", NATS_PASSWORD="packtest-canary-nats-admin-password-2b67")
        proc = subprocess.Popen(["nats", "--no-context", "--timeout", "3s", "--inbox-prefix", "_INBOX.emisar.admin",
                                 "sub", "--raw", "--count", "1", "--wait", "5s", inbox],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            request("admin", "$JS.API.CONSUMER.CREATE." + STREAM + ".push_example",
                    {"stream_name": STREAM, "action": "create", "config": {"name": "push_example", "durable_name": "push_example",
                     "deliver_subject": inbox, "filter_subject": "emisar.test", "ack_policy": "none", "deliver_policy": "all", "num_replicas": 1}})
            output, _ = proc.communicate(timeout=8)
            assert proc.returncode == 0 and PAYLOAD.encode() in output, "Raw admin authority counterexample did not deliver"
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        return {"raw_admin_can_arrange_indirect_delivery": True, "payload_was_not_printed": True}
    raise RuntimeError("Unknown fixture probe")


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed(sys.argv[2] if len(sys.argv) > 2 else "default")
        print("Real NATS fixture seeded")
    elif sys.argv[1] == "probe":
        print(json.dumps(probe(sys.argv[2], sys.argv[3:])))
    else:
        raise RuntimeError("Unknown fixture command")
