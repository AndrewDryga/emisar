#!/usr/bin/env python3
"""Signed-dispatch end-to-end check for the docker-compose stack.

Proves the CA-issued-certificate feature works through the WHOLE topology
(portal + runner + the real MCP bridge), not just in unit tests:

  1. runner-signed enforces signing — it trusts a CA `signing-init` minted at
     stack-up (generate-at-startup; no key material is committed).
  2. A dispatch SIGNED by the MCP bridge (using the matching leaf key + cert)
     to that runner RUNS.
  3. The SAME dispatch UNSIGNED is refused with `runner_requires_attestation`
     (the portal won't relay an unsigned call to an enforcing runner).

Signing is exercised through the actual `emisar-mcp` bridge — the bridge is what
builds the canonical claim and signs it — so this tests the real signer↔verifier
contract end to end, not a reimplementation.

Stdlib only (urllib + subprocess), like sso_e2e.py. Run via run.sh after the
stack is up. Exit 0 = pass.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request

PORTAL_URL = os.environ.get("PORTAL_URL", "http://localhost:4010")
MCP_KEY = os.environ.get("MCP_KEY", "emk-mcp-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD")
SIGNED_GROUP = os.environ.get("SIGNED_GROUP", "signed-iad")
ACTION = os.environ.get("SIGNED_ACTION", "linux.uptime")
REFUSAL_CODES = (
    "runner_requires_attestation",
    "signature_required",
    "cert_untrusted",
    "cert_expired",
    "cert_scope",
    "bad_signature",
)


def log(msg):
    print(f"[signed-dispatch-e2e] {msg}", flush=True)


def fail(msg):
    log(f"FAIL: {msg}")
    sys.exit(1)


def compose(*args, stdin=None, timeout=180):
    """Run `docker compose <args>` from the repo root, return (rc, stdout, stderr)."""
    proc = subprocess.run(
        ["docker", "compose", *args],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr


def find_runner(obj):
    """Recursively find the connected runner dict in group SIGNED_GROUP."""
    if isinstance(obj, dict):
        if obj.get("group") == SIGNED_GROUP and obj.get("name"):
            return obj
        for v in obj.values():
            found = find_runner(v)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = find_runner(v)
            if found:
                return found
    return None


def wait_for_enforcing_runner(deadline):
    """Poll the MCP runners list until the signed-iad runner is connected."""
    req = urllib.request.Request(
        f"{PORTAL_URL}/api/mcp/runners",
        headers={"Authorization": f"Bearer {MCP_KEY}"},
    )
    last = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode())
            runner = find_runner(body)
            if runner:
                status = str(runner.get("status", "")).lower()
                if "connect" in status or status in ("online", "up", ""):
                    return runner["name"]
                last = f"runner {runner['name']} present but status={status!r}"
            else:
                last = f"no runner in group {SIGNED_GROUP} yet"
        except Exception as exc:  # noqa: BLE001 — poll-and-retry
            last = f"runners query error: {exc}"
        time.sleep(2)
    fail(f"timed out waiting for an enforcing runner in group {SIGNED_GROUP} ({last})")


def read_material():
    """Read the freshly-minted leaf key + cert from the shared volume."""
    rc1, leaf, err1 = compose(
        "run", "--rm", "--no-deps", "-T", "--entrypoint", "cat",
        "signing-init", "/signing/leaf_key",
    )
    rc2, cert, err2 = compose(
        "run", "--rm", "--no-deps", "-T", "--entrypoint", "cat",
        "signing-init", "/signing/cert.json",
    )
    leaf, cert = leaf.strip(), cert.strip()
    if rc1 != 0 or not leaf:
        fail(f"could not read /signing/leaf_key (rc={rc1}): {err1.strip()}")
    if rc2 != 0 or not cert:
        fail(f"could not read /signing/cert.json (rc={rc2}): {err2.strip()}")
    return leaf, cert


def dispatch_frame(runner_name):
    return json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": ACTION,
            "arguments": {
                "runners": [runner_name],
                "reason": "signed-dispatch e2e",
                "wait": "30s",
            },
        },
    }) + "\n"


def run_bridge(frame, signing_env=None):
    """Drive the real emisar-mcp bridge with the frame on stdin; return its stdout."""
    extra = []
    for k, v in (signing_env or {}).items():
        extra += ["-e", f"{k}={v}"]
    rc, out, err = compose("run", "--rm", "-T", *extra, "mcp", stdin=frame)
    if rc != 0 and not out.strip():
        fail(f"bridge run failed (rc={rc}): {err.strip()}")
    return out.strip()


def has_refusal(text):
    return next((c for c in REFUSAL_CODES if c in text), None)


def main():
    deadline = time.time() + float(os.environ.get("E2E_TIMEOUT", "120"))

    log(f"waiting for an enforcing runner in group {SIGNED_GROUP}...")
    runner_name = wait_for_enforcing_runner(deadline)
    log(f"enforcing runner connected: {runner_name}")

    leaf, cert = read_material()
    log("read leaf key + cert from the shared volume")

    frame = dispatch_frame(runner_name)

    # 1. SIGNED dispatch must RUN.
    log(f"dispatching SIGNED {ACTION} -> {runner_name}")
    signed = run_bridge(frame, {"EMISAR_SIGNING_KEY": leaf, "EMISAR_SIGNING_CERT": cert})
    refusal = has_refusal(signed)
    if refusal:
        fail(f"a SIGNED dispatch was refused ({refusal}):\n{signed[:600]}")
    try:
        parsed = json.loads(signed.splitlines()[-1])
    except (ValueError, IndexError):
        fail(f"signed dispatch returned no JSON-RPC response:\n{signed[:600]}")
    if "result" not in parsed:
        fail(f"signed dispatch returned no result:\n{signed[:600]}")
    log("signed dispatch ran (result returned, no refusal) ✓")

    # 2. The SAME dispatch UNSIGNED must be refused.
    log(f"dispatching UNSIGNED {ACTION} -> {runner_name} (expect refusal)")
    unsigned = run_bridge(frame, None)
    if "runner_requires_attestation" not in unsigned:
        fail(
            "an UNSIGNED dispatch to an enforcing runner was NOT refused with "
            f"runner_requires_attestation:\n{unsigned[:600]}"
        )
    log("unsigned dispatch refused with runner_requires_attestation ✓")

    log("PASS — enforcing runner runs a signed dispatch and refuses an unsigned one")


if __name__ == "__main__":
    main()
