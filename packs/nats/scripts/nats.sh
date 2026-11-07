#!/bin/sh
set -eu
# Keep the complete implementation in this declared, hashed script. A sibling
# helper would not belong to the pack trust hash unless separately declared.
exec python3 -I - "$@" <<'PY'
"""Fixed JetStream RPCs; no application message reads or publications."""
import datetime
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

CAP = 4 * 1024 * 1024
I64 = 9223372036854775807
U64 = 18446744073709551615
SECONDS_MAX = I64 // 1000000000
NAME = re.compile(r"[A-Za-z0-9_-]{1,255}\Z")
SUBJECT = re.compile(r"(?:>|(?:[A-Za-z0-9_-]{1,64}|\*)(?:\.(?:[A-Za-z0-9_-]{1,64}|\*)){0,15}(?:\.>)?)\Z")
READS = {"connection_check", "account_info", "stream_names", "stream_info", "consumer_names", "consumer_info"}
TYPES = "io.nats.jetstream.api.v1."


class Failure(Exception):
    pass


def object_value(value):
    if type(value) is not dict:
        raise Failure("NATS response requires a JSON object.")
    return value


def array(value):
    if type(value) is not list:
        raise Failure("NATS response requires a JSON array.")
    return value


def integer(value, minimum=0, maximum=U64):
    if type(value) is not int or not minimum <= value <= maximum:
        raise Failure("NATS response contains an invalid integer.")
    return value


def number_text(value, minimum=0, maximum=U64):
    return str(integer(value, minimum, maximum))


def boolean(value):
    if type(value) is not bool:
        raise Failure("NATS response contains an invalid boolean.")
    return value


def text(value, limit):
    if type(value) is not str:
        raise Failure("NATS response contains an invalid string.")
    clean = "".join(" " if ord(c) < 32 or 127 <= ord(c) <= 159 else c for c in value)
    return clean if len(clean) <= limit else clean[:limit - 1] + "…"


def identity(value):
    if type(value) is not str or not NAME.fullmatch(value):
        raise Failure("NATS resource name must use at most 255 ASCII letters, digits, underscores or hyphens.")
    return value


def subject(value):
    if type(value) is not str or len(value) > 255 or not SUBJECT.fullmatch(value):
        raise Failure("NATS filter must be a bounded token/wildcard subject.")
    return value


def argument_integer(value, minimum, maximum):
    if type(value) is not str or not re.fullmatch(r"-?(?:0|[1-9][0-9]*)", value):
        raise Failure("NATS numeric argument must be a canonical decimal integer.")
    parsed = int(value)
    if not minimum <= parsed <= maximum:
        raise Failure("NATS numeric argument exceeds the supported integer range.")
    return parsed


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Failure("NATS JSON contains duplicate fields.")
            result[key] = value
        return result

    def noninteger(_):
        raise Failure("NATS JSON contains a non-integer numeric field.")

    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_float=noninteger, parse_constant=noninteger)
    except (ValueError, UnicodeError, RecursionError):
        raise Failure("NATS did not return one valid JSON document.") from None


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()


def emit(value):
    data = encode(value)
    # Match the runner Go encoder, which escapes these two codepoints.
    wire_bytes = len(data) + 3 * (data.count(b"\xe2\x80\xa8") + data.count(b"\xe2\x80\xa9"))
    if wire_bytes > 8192:
        raise Failure("Projected NATS result exceeds the structured-output budget.")
    print(data.decode())


def transport_reason(stderr):
    value = stderr.lower()
    if b"permission" in value:
        return "NATS permission denied"
    if b"authorization" in value or b"authentication" in value:
        return "NATS authentication failed"
    if any(word in value for word in (b"certificate", b"x509", b"tls handshake", b"tls: ", b"secure connection")):
        return "TLS verification failed"
    if b"no responders" in value:
        return "no JetStream responder is available"
    if b"timeout" in value or b"deadline" in value:
        return "NATS request timed out"
    return "NATS transport failed or returned no response"


class Client:
    def __init__(self, role):
        original = os.environ
        urls = original.get("NATS_URL", "").split(",")
        endpoint = re.compile(r"tls://(?:[A-Za-z0-9][A-Za-z0-9.-]{0,252}|\[[0-9A-Fa-f:]+\])(?::[0-9]{1,5})?\Z")
        if not 1 <= len(urls) <= 4 or any(not endpoint.fullmatch(u) for u in urls):
            raise Failure("NATS_URL must contain one to four TLS seed URLs without userinfo, paths or queries.")
        ca = original.get("NATS_CA", "")
        if not ca or not os.path.isfile(ca) or not os.access(ca, os.R_OK):
            raise Failure("NATS_CA must name a readable certificate-authority file.")
        user = original.get("NATS_" + role.upper() + "_USER", "")
        password = original.get("NATS_" + role.upper() + "_PASSWORD", "")
        if not user or not password:
            raise Failure("The selected NATS role is not configured in the runner environment.")
        # No inherited context, alternate auth, proxy, TLS override or other
        # role credential reaches the child. Only its selected native auth.
        self.env = {k: original[k] for k in ("PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR") if k in original}
        self.env.update(NATS_URL=",".join(urls), NATS_CA=ca, NATS_USER=user, NATS_PASSWORD=password)
        self.prefix = "_INBOX.emisar." + role
        self.urls = urls

    def capture(self, argv, body=b"", seconds=8):
        if len(body) > CAP:
            raise Failure("NATS request exceeds the 4 MiB private-input budget.")
        # The unlinked mode-0600 input holds private RMW config, never auth.
        # No configuration body or credential appears in the process argv.
        with tempfile.TemporaryFile() as input_file:
            input_file.write(body)
            input_file.seek(0)
            try:
                proc = subprocess.Popen(argv, stdin=input_file, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=self.env, start_new_session=True)
            except OSError:
                raise Failure("Could not start the native NATS CLI.") from None
            stdout, stderr = bytearray(), bytearray()
            deadline = time.monotonic() + seconds
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(proc.stdout, selectors.EVENT_READ, "stdout")
                    selector.register(proc.stderr, selectors.EVENT_READ, "stderr")
                    while selector.get_map():
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise Failure("Native NATS CLI exceeded its bounded deadline.")
                        for key, _ in selector.select(remaining):
                            chunk = os.read(key.fileobj.fileno(), 65536)
                            if not chunk:
                                selector.unregister(key.fileobj)
                                key.fileobj.close()
                            elif key.data == "stdout":
                                if len(stdout) + len(chunk) > CAP:
                                    raise Failure("NATS response exceeds the 4 MiB capture budget.")
                                stdout.extend(chunk)
                            elif len(stderr) < 8192:
                                stderr.extend(chunk[:8192 - len(stderr)])
                    try:
                        code = proc.wait(timeout=max(0.001, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        raise Failure("Native NATS CLI exceeded its bounded deadline.") from None
                if code != 0 or not stdout.strip():
                    raise Failure(transport_reason(stderr) + "; no successful JSON result.")
                self.last_stderr = bytes(stderr)
                return decode(stdout)
            finally:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                proc.wait()
                for pipe in (proc.stdout, proc.stderr):
                    if not pipe.closed:
                        pipe.close()

    def command(self):
        return ["nats", "--no-context", "--inbox-prefix", self.prefix, "--timeout", "5s"]

    def rpc(self, rpc_subject, payload, response_type):
        result = object_value(self.capture(self.command() + ["request", "--raw", "--no-templates", "--force-stdin", rpc_subject], encode(payload)))
        if result.get("error") is not None:
            error = object_value(result["error"])
            code = integer(error.get("code"), 0, 999)
            detail = integer(error.get("err_code", 0), 0, I64)
            message = text(error.get("description", "JetStream rejected the request"), 256)
            raise Failure(json.dumps({"code": code, "err_code": detail, "message": message}, ensure_ascii=False))
        if result.get("type") != TYPES + response_type:
            raise Failure("NATS returned an unexpected JetStream response type.")
        return result


def cluster(value):
    if value is None:
        return {"name": "", "leader": "", "leader_truncated": False, "replicas": [], "replicas_omitted": 0}
    value = object_value(value)
    peers = array(value.get("replicas", []))
    leader = value.get("leader", "")
    return {"name": text(value.get("name", ""), 48), "leader": text(leader, 48), "leader_truncated": len(leader) > 48,
            "replicas": [{"name": text(object_value(p).get("name", ""), 48),
                          "name_truncated": len(p.get("name", "")) > 48,
                          "current": boolean(p.get("current", False)), "offline": boolean(p.get("offline", False)),
                          "lag": number_text(p.get("lag", 0)), "active_ns": number_text(p.get("active", 0))} for p in peers[:5]],
            "replicas_omitted": max(0, len(peers) - 5)}


def subjects(values):
    values = array(values)
    return [{"value": text(v, 96), "truncated": len(v) > 96} for v in values[:4]], max(0, len(values) - 4)


def stream_info(value, name):
    cfg = object_value(value.get("config"))
    if cfg.get("name") != name:
        raise Failure("NATS returned a different stream identity.")
    state = object_value(value.get("state"))
    filters, omitted = subjects(cfg.get("subjects", []))
    return {"name": name, "created": text(value.get("created", ""), 40),
            "storage": text(cfg.get("storage", ""), 16), "retention": text(cfg.get("retention", ""), 16),
            "replicas": integer(cfg.get("num_replicas", 1), 1, 5), "subjects": filters, "subjects_omitted": omitted,
            "max_messages": number_text(cfg.get("max_msgs", -1), -1, I64), "max_bytes": number_text(cfg.get("max_bytes", -1), -1, I64),
            "max_age_ns": number_text(cfg.get("max_age", 0), 0, I64),
            "messages": number_text(state.get("messages", 0)), "bytes": number_text(state.get("bytes", 0)),
            "first_sequence": number_text(state.get("first_seq", 0)), "last_sequence": number_text(state.get("last_seq", 0)),
            "consumer_count": number_text(state.get("consumer_count", 0)), "cluster": cluster(value.get("cluster"))}


def consumer_info(value, stream, consumer):
    cfg = object_value(value.get("config"))
    if value.get("stream_name") != stream or value.get("name") != consumer:
        raise Failure("NATS returned a different consumer identity.")
    filters, omitted = subjects(cfg.get("filter_subjects", []))
    single = cfg.get("filter_subject", "")
    delivered = object_value(value.get("delivered", {}))
    floor = object_value(value.get("ack_floor", {}))
    return {"stream": stream, "name": consumer, "created": text(value.get("created", ""), 40),
            "pull": not bool(cfg.get("deliver_subject")), "ack_policy": text(cfg.get("ack_policy", ""), 16),
            "deliver_policy": text(cfg.get("deliver_policy", ""), 24),
            "filter_subject": text(single, 96), "filter_subject_truncated": len(single) > 96,
            "filter_subjects": filters, "filter_subjects_omitted": omitted,
            "ack_wait_ns": number_text(cfg.get("ack_wait", 0), 0, I64), "max_deliver": number_text(cfg.get("max_deliver", -1), -1, I64),
            "max_ack_pending": number_text(cfg.get("max_ack_pending", 0), -1, I64),
            "pending": number_text(value.get("num_pending", 0)), "ack_pending": number_text(value.get("num_ack_pending", 0)),
            "redelivered": number_text(value.get("num_redelivered", 0)), "waiting": number_text(value.get("num_waiting", 0)),
            "delivered_sequence": number_text(delivered.get("stream_seq", 0)), "ack_floor_sequence": number_text(floor.get("stream_seq", 0)),
            "paused": boolean(value.get("paused", False)), "pause_until": text(cfg["pause_until"], 40) if cfg.get("pause_until") else None,
            "cluster": cluster(value.get("cluster"))}


def success(value):
    if value.get("success") is not True:
        raise Failure("JetStream did not acknowledge the requested change.")


def run(mode, args):
    client = Client("read" if mode in READS else "admin")
    if mode == "connection_check":
        rows = array(client.capture(client.command() + ["rtt", "1", "--json"], seconds=25))
        if len(rows) != len(client.urls):
            raise Failure("NATS RTT did not cover the configured endpoints.")
        endpoints = []
        for row, url in zip(rows, client.urls):
            row = object_value(row)
            results = array(row.get("results"))
            if row.get("url") != url or not results or len(results) > 1024:
                raise Failure("NATS RTT returned an unexpected endpoint/result set.")
            times = []
            for result in results:
                duration = object_value(result).get("rtt")
                if type(duration) is not int or not 1 <= duration <= I64:
                    raise Failure(transport_reason(client.last_stderr) + "; native RTT did not succeed.")
                times.append(duration)
            endpoints.append({"endpoint": url, "addresses_checked": len(times), "min_rtt_ns": str(min(times)), "max_rtt_ns": str(max(times))})
        return {"connected": True, "endpoints": endpoints}
    if mode == "account_info":
        data = client.rpc("$JS.API.INFO", {}, "account_info_response")
        limits, api = object_value(data.get("limits", {})), object_value(data.get("api", {}))
        return {"memory_bytes": number_text(data.get("memory", 0)), "storage_bytes": number_text(data.get("storage", 0)),
                "reserved_memory_bytes": number_text(data.get("reserved_memory", 0)), "reserved_storage_bytes": number_text(data.get("reserved_storage", 0)),
                "streams": number_text(data.get("streams", 0)), "consumers": number_text(data.get("consumers", 0)),
                "limits": {k: number_text(limits.get(k, -1), -1, I64) for k in ("max_memory", "max_storage", "max_streams", "max_consumers", "max_ack_pending")},
                "api_total": number_text(api.get("total", 0)), "api_errors": number_text(api.get("errors", 0))}
    if mode in ("stream_names", "consumer_names"):
        stream = identity(args[0]) if mode == "consumer_names" else None
        offset = argument_integer(args[-1], 0, 9007199254740991)
        kind = "consumer" if stream else "stream"
        rpc = "$JS.API." + kind.upper() + ".NAMES" + ("." + stream if stream else "")
        data = client.rpc(rpc, {"offset": offset}, kind + "_names_response")
        total = integer(data.get("total", 0))
        actual_offset = integer(data.get("offset", 0))
        raw_names = data.get("consumers" if stream else "streams")
        # Native NamesResponse slices serialize as null when empty (no
        # omitempty tag). Only a terminal page may have no names.
        names = [] if raw_names is None else array(raw_names)
        if actual_offset != offset or len(names) > 1024:
            raise Failure("NATS names response has an invalid offset or page size.")
        if offset < total and not names:
            raise Failure("NATS names response is empty before its declared total.")
        # Exact whole names, never a clipped target. ASCII names cost at most
        # 255 bytes each; ten plus the fixed envelope fit well below 8 KiB.
        shown = [identity(n) for n in names[:10]]
        next_offset = offset + len(shown)
        if next_offset < total and next_offset > 9007199254740991:
            raise Failure("NATS continuation exceeds the exact JSON offset range.")
        return {"names": shown, "offset": offset, "total": str(total),
                "next_offset": next_offset if next_offset < total else None,
                "omitted_in_response": max(0, len(names) - len(shown))}
    stream = identity(args[0])
    consumer = identity(args[1]) if mode in {"consumer_info", "create_consumer", "update_consumer_limits", "pause_consumer", "resume_consumer", "step_down_consumer_leader", "delete_consumer"} else None
    if mode == "stream_info":
        return stream_info(client.rpc("$JS.API.STREAM.INFO." + stream, {}, "stream_info_response"), stream)
    if mode == "consumer_info":
        return consumer_info(client.rpc("$JS.API.CONSUMER.INFO." + stream + "." + consumer, {}, "consumer_info_response"), stream, consumer)
    if mode == "create_stream":
        pattern, storage, retention = subject(args[1]), args[2], args[3]
        if storage not in ("file", "memory") or retention not in ("limits", "workqueue", "interest"):
            raise Failure("Unsupported NATS storage or retention selection.")
        body = {"name": stream, "subjects": [pattern], "storage": storage, "retention": retention,
                "max_bytes": argument_integer(args[4], 1, I64), "max_msgs": argument_integer(args[5], 1, I64),
                "num_replicas": argument_integer(args[6], 1, 5), "max_age": argument_integer(args[7], 0, SECONDS_MAX) * 1000000000}
        return stream_info(client.rpc("$JS.API.STREAM.CREATE." + stream, body, "stream_create_response"), stream)
    if mode == "create_consumer":
        delivery = args[3]
        if delivery not in ("all", "new", "last"):
            raise Failure("Unsupported consumer delivery selection.")
        cfg = {"name": consumer, "durable_name": consumer, "filter_subject": subject(args[2]), "ack_policy": "explicit", "deliver_policy": delivery,
               "ack_wait": argument_integer(args[4], 1, SECONDS_MAX) * 1000000000, "max_ack_pending": argument_integer(args[5], 1, I64),
               "max_deliver": argument_integer(args[6], -1, I64), "num_replicas": argument_integer(args[7], 1, 5)}
        if cfg["max_deliver"] == 0:
            raise Failure("Consumer max_deliver must be -1 or positive.")
        data = client.rpc("$JS.API.CONSUMER.CREATE." + stream + "." + consumer, {"stream_name": stream, "config": cfg, "action": "create"}, "consumer_create_response")
        return consumer_info(data, stream, consumer)
    if mode in ("update_stream_limits", "update_consumer_limits"):
        changes = {}
        if consumer:
            for key, raw in zip(("max_ack_pending", "max_deliver"), args[2:4]):
                if raw:
                    changes[key] = argument_integer(raw, -1, I64)
                    if changes[key] == 0:
                        raise Failure("Consumer limits must be -1 or positive.")
            seconds = argument_integer(args[4], 0, SECONDS_MAX)
            if seconds:
                changes["ack_wait"] = seconds * 1000000000
        else:
            for key, raw in zip(("max_bytes", "max_msgs"), args[1:3]):
                if raw:
                    changes[key] = argument_integer(raw, -1, I64)
                    if changes[key] == 0:
                        raise Failure("Stream limits must be -1 or positive.")
            seconds = argument_integer(args[3], -1, SECONDS_MAX)
            if seconds >= 0:
                changes["max_age"] = seconds * 1000000000
        if not changes:
            raise Failure("At least one NATS limit change is required.")
        if consumer:
            before = client.rpc("$JS.API.CONSUMER.INFO." + stream + "." + consumer, {}, "consumer_info_response")
            consumer_info(before, stream, consumer)
        else:
            before = client.rpc("$JS.API.STREAM.INFO." + stream, {}, "stream_info_response")
            stream_info(before, stream)
        cfg = before["config"]
        cfg.update(changes)
        if consumer:
            after = client.rpc("$JS.API.CONSUMER.CREATE." + stream + "." + consumer, {"stream_name": stream, "config": cfg, "action": "update"}, "consumer_create_response")
        else:
            after = client.rpc("$JS.API.STREAM.UPDATE." + stream, cfg, "stream_update_response")
        if any(object_value(after.get("config")).get(k, 0) != v for k, v in changes.items()):
            raise Failure("JetStream did not return the requested limit values.")
        return consumer_info(after, stream, consumer) if consumer else stream_info(after, stream)
    if mode in ("pause_consumer", "resume_consumer"):
        payload = {}
        if mode == "pause_consumer":
            seconds = argument_integer(args[2], 1, SECONDS_MAX)
            until = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)
            payload["pause_until"] = until.isoformat().replace("+00:00", "Z")
        data = client.rpc("$JS.API.CONSUMER.PAUSE." + stream + "." + consumer, payload, "consumer_pause_response")
        paused = boolean(data.get("paused"))
        if paused != (mode == "pause_consumer"):
            raise Failure("JetStream did not reach the requested pause state.")
        return {"stream": stream, "consumer": consumer, "paused": paused,
                "pause_until": text(data.get("pause_until", ""), 40) if paused else None,
                "remaining_ns": number_text(data.get("pause_remaining", 0), 0, I64)}
    if mode == "step_down_stream_leader":
        data = client.rpc("$JS.API.STREAM.LEADER.STEPDOWN." + stream, {}, "stream_leader_stepdown_response")
    elif mode == "step_down_consumer_leader":
        data = client.rpc("$JS.API.CONSUMER.LEADER.STEPDOWN." + stream + "." + consumer, {}, "consumer_leader_stepdown_response")
    elif mode == "delete_message":
        sequence = argument_integer(args[1], 1, U64)
        data = client.rpc("$JS.API.STREAM.MSG.DELETE." + stream, {"seq": sequence}, "stream_msg_delete_response")
    elif mode == "delete_consumer":
        data = client.rpc("$JS.API.CONSUMER.DELETE." + stream + "." + consumer, {}, "consumer_delete_response")
    elif mode == "purge_stream":
        data = client.rpc("$JS.API.STREAM.PURGE." + stream, {}, "stream_purge_response")
    elif mode == "delete_stream":
        data = client.rpc("$JS.API.STREAM.DELETE." + stream, {}, "stream_delete_response")
    else:
        raise Failure("Unsupported native NATS action.")
    success(data)
    result = {"accepted": True, "stream": stream}
    if consumer:
        result["consumer"] = consumer
    if mode == "delete_message":
        result["sequence"] = str(sequence)
    if mode == "purge_stream":
        result["purged"] = number_text(data.get("purged"))
    return result


def interrupted(sig, _frame):
    raise SystemExit(128 + sig)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        emit(run(sys.argv[1], sys.argv[2:]))
    except Failure as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
    except (IndexError, KeyError, TypeError, ValueError, OverflowError, RecursionError):
        print("Native NATS input or response failed strict validation.", file=sys.stderr)
        raise SystemExit(1)
PY
