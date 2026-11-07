"""Boundary regressions supplement real curl/TLS contract behavior."""
import json
import os
from pathlib import Path
import sys
import unittest

source = (Path(__file__).parents[1] / "scripts/betterstack.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
ns = {"__name__": "betterstack_codec_test"}
exec(compile(source, "declared-betterstack-script", "exec"), ns)
Failure = ns["Failure"]


class Boundaries(unittest.TestCase):
    def test_strict_json(self):
        for raw in (b"", b"{}{}", b'{"data":{},"data":{}}', b'{"x":NaN}', b'{"x":1e400}', b'[]', b'{"errors":"hidden"}'):
            with self.subTest(raw=raw), self.assertRaises(Failure): ns["strict_json"](raw)

    def test_public_url(self):
        for value in ("https://u:p@example.com/", "https://example.com/?password=p", "https://example.com/#x", "https://127.0.0.1/", "https://[::1]/", "https://2130706433/", "https://0x7f000001/", "https://localhost/", "https://foo.local/", "https://example.com\\@127.0.0.1/", "https://example.com/\n"):
            with self.subTest(value=value), self.assertRaises(Failure): ns["public_url"](value)
        for value in ("https://example.com/health", "https://8.8.8.8/", "http://[2606:4700:4700::1111]:80/health"):
            self.assertEqual(ns["public_url"](value), value)

    def test_types_are_not_coerced(self):
        for value in (True, -1, 1.2, "1", None):
            with self.assertRaises(Failure): ns["integer"](value)
        for value in ("1\n", "0", "01", "123456789012345678901", 123):
            with self.assertRaises(Failure): ns["identifier"](value)
        for value in ("secret", "2026-02-30T12:34:56Z", "2026-11-07T25:00:00Z"):
            with self.assertRaises(Failure): ns["timestamp"](value)

    def test_independent_capture(self):
        env = {"PATH": os.environ["PATH"]}
        with self.assertRaisesRegex(Failure, "independent byte budget"):
            ns["capture"]([sys.executable, "-I", "-c", "import sys;sys.stdin.buffer.read();sys.stdout.buffer.write(b'x'*4194309)"], b"private", env)
        with self.assertRaisesRegex(Failure, "independent byte budget"):
            ns["capture"]([sys.executable, "-I", "-c", "import sys;sys.stdin.buffer.read();sys.stderr.buffer.write(b'x'*8193)"], b"private", env)
        with self.assertRaisesRegex(Failure, "independent deadline"):
            ns["capture"]([sys.executable, "-I", "-c", "import sys,time;sys.stdin.buffer.read();time.sleep(5)"], b"private", env, seconds=0.1)
        with self.assertRaisesRegex(Failure, "independent deadline"):
            ns["capture"]([sys.executable, "-I", "-c", "import time;time.sleep(5)"], b"x" * 131072, env, seconds=0.1)
        code, raw = ns["capture"]([sys.executable, "-I", "-c", "import sys;sys.stdin.buffer.read();sys.exit(7)"], b"private", env)
        self.assertEqual((code, raw), (7, b""))

    def test_selected_credential_custody(self):
        original = ns["capture"]
        def inspect(argv, config, env):
            self.assertNotIn("BETTERSTACK_API_TOKEN", env)
            self.assertNotIn("UNRELATED_CREDENTIAL", env)
            self.assertNotIn("HTTPS_PROXY", env)
            self.assertNotIn("SSLKEYLOGFILE", env)
            self.assertFalse(any("packtest-canary" in x for x in argv))
            self.assertIn(b"Authorization: Bearer packtest-canary-betterstack-access-e391", config)
            self.assertEqual(argv[argv.index("--url") + 1], "https://incidents.betterstack.com/api/v2/monitors")
            return 0, b'{"data":[]}\n200'
        ns["capture"] = inspect
        try: self.assertEqual(ns["request"]("GET", "/api/v2/monitors"), {"data": []})
        finally: ns["capture"] = original


unittest.main()
