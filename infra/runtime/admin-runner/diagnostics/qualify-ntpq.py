"""Exercise the real private ntpq interpreter against an isolated mode-6 peer."""

import socket
import struct
import subprocess
import sys
import pathlib
import os
import importlib.util

# The production COS service database maps NTP to UDP 123. Keep named-service
# resolution so qualification exercises the unchanged Debian client's lookup.
assert socket.getservbyname("ntp", "udp") == 123


def query(wrapper, malformed, cwd, environment):
    address = socket.getaddrinfo(
        "localhost", "ntp", socket.AF_UNSPEC, socket.SOCK_DGRAM, socket.IPPROTO_UDP
    )[0]
    with socket.socket(address[0], address[1], address[2]) as peer:
        # Docker's private network namespace permits this without granting any
        # capability. The production tool's fixed localhost:123 path is tested.
        peer.bind(address[4])
        peer.settimeout(5)
        process = subprocess.Popen(
            [wrapper, "-pn"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=cwd, env=environment,
        )
        try:
            requests = [(1, 0)] if malformed else [(1, 0), (2, 1)]
            for opcode, association in requests:
                request, client = peer.recvfrom(512)
                assert len(request) == 12, "unexpected NTP control request size"
                mode, flags, sequence, _, associd, offset, count = struct.unpack(
                    "!BBHHHHH", request
                )
                assert mode & 7 == 6 and flags & 0xE0 == 0
                assert flags & 0x1F == opcode and associd == association
                assert offset == 0 and count == 0
                if opcode == 1:
                    payload = b"\x00\x01\x96" if malformed else struct.pack("!HH", 1, 0x9600)
                    status = 0
                else:
                    payload = (
                        b"srcadr=192.0.2.1, refid=198.51.100.1, stratum=2, hmode=3, "
                        b"hpoll=6, ppoll=6, reach=0xff, delay=1.250, offset=-0.500, jitter=0.125"
                    )
                    status = 0x9600
                response = struct.pack(
                    "!BBHHHHH", mode, 0x80 | opcode, sequence, status, associd, 0, len(payload)
                ) + payload
                response += b"\x00" * (-len(response) % 4)
                peer.sendto(response, client)
            output, error = process.communicate(timeout=5)
            assert process.returncode == 0, (process.returncode, output, error)
            assert "Traceback" not in error, error
            if malformed:
                # This pinned ntpq reports malformed control data as a warning,
                # not a nonzero exit; do not invent stronger CLI semantics.
                assert not output, output
                assert "***Response length should have been a multiple of 4" in error, error
            else:
                assert not error, error
                rows = [line.split() for line in output.splitlines() if line.startswith("*192.0.2.1")]
                assert len(rows) == 1, output
                row = rows[0]
                assert len(row) == 10, output
                assert row[:4] == ["*192.0.2.1", "198.51.100.1", "2", "u"], output
                assert row[5:7] == ["64", "377"], output
                assert [float(value) for value in row[7:]] == [1.25, -0.5, 0.125], output
                print(output, end="")
        except BaseException as failure:
            if process.poll() is None:
                process.kill()
            output, error = process.communicate()
            raise AssertionError((str(failure), output, error)) from failure
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


assert sys.flags.dont_write_bytecode and sys.flags.no_site and sys.flags.safe_path
hostile = pathlib.Path("/run/diagnostics-hostile-imports")
user_base = hostile / "user"
cwd = hostile / "cwd"
user_site = user_base / "lib/python3.11/site-packages"
cwd.mkdir(parents=True)
user_site.mkdir(parents=True)
for directory in (cwd, user_site):
    for name in ("sitecustomize", "usercustomize", "ntp", "xml", "ssl", "sqlite3", "tarfile"):
        (directory / (name + ".py")).write_text("raise RuntimeError('untrusted Python import')\n")
environment = dict(os.environ, PYTHONUSERBASE=str(user_base), PYTHONPATH=str(cwd))
os.environ["PYTHONUSERBASE"] = str(user_base)
os.chdir(cwd)
assert all(importlib.util.find_spec(name) is None for name in ("sqlite3", "_sqlite3", "xml", "ssl", "_ssl", "tarfile"))
query(sys.argv[1], malformed=False, cwd=cwd, environment=environment)
query(sys.argv[1], malformed=True, cwd=cwd, environment=environment)
assert not list(hostile.rglob("*.pyc")), "hostile modules were loaded or bytecode was written"
print("ntpq peers and malformed mode-6 response qualified")
