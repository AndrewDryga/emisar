"""Supplement real vendor cases with strict codec and child-I/O regressions."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import unittest

import fixture

source = (Path(__file__).parents[1] / "scripts/nats.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
ns = {"__name__": "nats_pack_codec_test"}
exec(compile(source, "declared-nats-script", "exec"), ns)
Failure = ns["Failure"]


class Codec(unittest.TestCase):
    def test_strict_json(self):
        for raw in (b"", b'{}{}', b'{"a":1,"a":2}', b'{"value":NaN}', b'{"value":1.5}'):
            with self.subTest(raw=raw), self.assertRaises(Failure):
                ns["decode"](raw)

    def test_integer_precision_and_templates(self):
        value = {"max_age": 9223372036000000000, "seq": 18446744073709551615,
                 "metadata": {"literal": "{{Count}}"}}
        self.assertEqual(ns["decode"](ns["encode"](value)), value)

    def test_false_acknowledgements(self):
        for value in ({}, {"success": False}, {"success": 1}):
            with self.assertRaises(Failure):
                ns["success"](value)

    def test_tls_url_does_not_hide_authentication_error(self):
        self.assertEqual(ns["transport_reason"](b"Failed RTT for tls://server: authorization violation"), "NATS authentication failed")
        self.assertEqual(ns["transport_reason"](b"Failed RTT for tls://server: x509: unknown authority"), "TLS verification failed")

    def test_provider_error_and_type(self):
        client = ns["Client"]("read")
        client.capture = lambda *_: {"error": {"code": 404, "err_code": 10059,
                                               "description": "stream not found", "private": fixture.PRIVATE}}
        with self.assertRaises(Failure) as caught:
            client.rpc("$JS.API.INFO", {}, "account_info_response")
        self.assertIn("10059", str(caught.exception))
        self.assertNotIn(fixture.PRIVATE, str(caught.exception))
        client.capture = lambda *_: {"type": "wrong"}
        with self.assertRaises(Failure):
            client.rpc("$JS.API.INFO", {}, "account_info_response")

    def test_private_input_and_selected_environment(self):
        client = ns["Client"]("read")
        self.assertNotIn("NATS_ADMIN_PASSWORD", client.env)
        self.assertNotIn("NATS_READ_PASSWORD", client.env)
        self.assertTrue(set(client.env) <= {"PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "NATS_URL", "NATS_CA", "NATS_USER", "NATS_PASSWORD"})
        body = fixture.PRIVATE.encode()
        program = "import os,sys,json; body=sys.stdin.buffer.read(); print(json.dumps({'stdin':len(body)>0,'argv':all('private-metadata' not in a for a in sys.argv),'keys':sorted(k for k in os.environ if k.startswith('NATS_'))}))"
        result = client.capture([sys.executable, "-c", program], body)
        self.assertTrue(result["stdin"])
        self.assertTrue(result["argv"])
        self.assertEqual(result["keys"], ["NATS_CA", "NATS_PASSWORD", "NATS_URL", "NATS_USER"])

    def test_capture_cap_deadline_and_empty_success(self):
        client = ns["Client"]("read")
        with self.assertRaisesRegex(Failure, "capture budget"):
            client.capture([sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'x'*4194305)"])
        with self.assertRaisesRegex(Failure, "bounded deadline"):
            client.capture([sys.executable, "-c", "import time;time.sleep(5)"], seconds=0.1)
        with self.assertRaisesRegex(Failure, "no successful JSON"):
            client.capture([sys.executable, "-c", "pass"])
        with self.assertRaises(Failure) as caught:
            client.capture([sys.executable, "-c", "import sys;sys.stderr.write('" + fixture.PRIVATE + "');sys.exit(1)"])
        self.assertNotIn(fixture.PRIVATE, str(caught.exception))

    def test_worst_projected_results_fit(self):
        # Start from actual server responses; mutate only presentation fields
        # for a codec size proof, not a substitute transport/vendor SUT.
        stream = fixture.request("read", "$JS.API.STREAM.INFO.EMISAR_TEST", {})
        consumer = fixture.request("read", "$JS.API.CONSUMER.INFO.EMISAR_TEST.worker", {})
        strange = "\u2028" * 300
        peer = {"name": strange, "current": True, "offline": False,
                "lag": 18446744073709551615, "active": 9223372036854775807}
        cluster = {"name": strange, "leader": strange, "replicas": [copy.deepcopy(peer) for _ in range(7)]}
        name = "S" * 255
        stream["config"]["name"] = name
        stream["config"]["subjects"] = [strange] * 7
        stream["created"] = strange
        stream["cluster"] = cluster
        consumer["stream_name"] = name
        consumer["name"] = "C" * 255
        consumer["created"] = strange
        consumer["config"]["filter_subject"] = strange
        consumer["config"]["filter_subjects"] = [strange] * 7
        consumer["cluster"] = cluster
        for result in (ns["stream_info"](stream, name), ns["consumer_info"](consumer, name, "C" * 255)):
            with contextlib.redirect_stdout(io.StringIO()) as captured:
                ns["emit"](result)
            self.assertLessEqual(len(captured.getvalue().replace("\u2028", "\\u2028").encode()), 8192)


if __name__ == "__main__":
    unittest.main()
