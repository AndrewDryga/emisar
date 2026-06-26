#!/usr/bin/env python3
"""
SSO end-to-end driver for the docker-compose stack. Reaches the portal and
Keycloak over host.docker.internal (the published 4010 + 8443), the SAME path a
host browser takes — so the OIDC issuer + redirect_uri are consistent across the
browser, the portal container, and this driver, and a green run proves the
host-browser flow works.

Tests both halves against the seeded Keycloak IdentityProvider:

  1. SCIM  — provision (POST), read (GET), then deprovision (PATCH active:false)
             a user against /scim/v2 with the fixed dev bearer.
  2. OIDC  — the full auth-code login as alice through Keycloak's real login
             page, landing back on emisar's /sign_in/sso/callback → JIT-provision.

Exit 0 on success, non-zero on any failure. Stdlib only. DEV ONLY.
"""
import html
import http.cookiejar
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORTAL = os.environ["PORTAL_URL"]
ISSUER = os.environ["KEYCLOAK_ISSUER"]
CA = os.environ["KEYCLOAK_CA"]
PROVIDER_ID = os.environ["PROVIDER_ID"]
SCIM_TOKEN = os.environ["SCIM_TOKEN"]
KC_USER = os.environ["KC_USER"]
KC_PASS = os.environ["KC_PASS"]

# Trust the dev CA for HTTPS calls to Keycloak (the portal trusts the same CA
# via update-ca-certificates → :public_key.cacerts_get/0).
SSL_CTX = ssl.create_default_context(cafile=CA)


def log(msg):
    print(f"[sso-e2e] {msg}", flush=True)


def fail(msg):
    log(f"FAIL: {msg}")
    sys.exit(1)


def wait_for(name, fn, tries=60, delay=2):
    last = None
    for _ in range(tries):
        try:
            if fn():
                log(f"{name} ready")
                return
        except Exception as e:  # noqa: BLE001 — readiness probe, any error retries
            last = e
        time.sleep(delay)
    fail(f"{name} not ready after {tries * delay}s (last error: {last})")


# ---- readiness -------------------------------------------------------------

def portal_ready():
    with urllib.request.urlopen(f"{PORTAL}/healthz", timeout=5) as r:
        return r.status == 200


def keycloak_ready():
    url = f"{ISSUER}/.well-known/openid-configuration"
    with urllib.request.urlopen(url, timeout=5, context=SSL_CTX) as r:
        return json.load(r).get("issuer") == ISSUER


# ---- SCIM ------------------------------------------------------------------

def scim(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{PORTAL}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {SCIM_TOKEN}")
    req.add_header("Content-Type", "application/scim+json")
    req.add_header("Accept", "application/scim+json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else {})


def test_scim():
    log("SCIM: provisioning carol@northstar.example …")
    user = {
        "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName": "carol@northstar.example",
        "name": {"givenName": "Carol", "familyName": "SCIM"},
        "emails": [{"value": "carol@northstar.example", "primary": True}],
        "active": True,
        "externalId": "kc-carol-1",
    }
    status, resp = scim("POST", "/scim/v2/Users", user)
    if status not in (200, 201):
        fail(f"SCIM create returned {status}: {resp}")
    uid = resp.get("id")
    if not uid:
        fail(f"SCIM create missing id: {resp}")
    log(f"SCIM: created id={uid} active={resp.get('active')} ✓")

    status, resp = scim("GET", f"/scim/v2/Users/{uid}")
    if status != 200 or resp.get("active") is not True:
        fail(f"SCIM read-after-create unexpected: {status} {resp}")
    log("SCIM: read back active=true ✓")

    log("SCIM: deprovisioning (active:false) …")
    patch = {
        "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations": [{"op": "replace", "path": "active", "value": False}],
    }
    status, resp = scim("PATCH", f"/scim/v2/Users/{uid}", patch)
    if status not in (200, 204):
        fail(f"SCIM deprovision returned {status}: {resp}")

    status, resp = scim("GET", f"/scim/v2/Users/{uid}")
    if status == 200 and resp.get("active") is not False:
        fail(f"SCIM user still active after deprovision: {resp}")
    log("SCIM: deprovision confirmed ✓")
    log("SCIM e2e PASSED")


# ---- OIDC ------------------------------------------------------------------

def test_oidc():
    log("OIDC: auth-code login as alice …")
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=SSL_CTX),
    )

    # 1) begin → portal 302 to Keycloak → Keycloak login page (urllib follows the 302).
    with op.open(f"{PORTAL}/sign_in/sso/{PROVIDER_ID}", timeout=20) as r:
        login_html = r.read().decode(errors="replace")
        login_url = r.geturl()
    if not login_url.startswith(ISSUER):
        fail(f"begin did not reach the Keycloak issuer (got {login_url}) — discovery/TLS-trust failed")
    log("OIDC: portal discovered Keycloak over TLS + redirected to login — trust OK ✓")

    # 2) parse the Keycloak login-form action + POST alice's credentials.
    m = re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', login_html)
    if not m:
        fail("could not find the Keycloak login form action")
    action = html.unescape(m.group(1))
    data = urllib.parse.urlencode(
        {"username": KC_USER, "password": KC_PASS, "credentialId": ""}
    ).encode()

    # 3) POST → Keycloak 302 back to the portal callback → portal exchanges the
    #    code (token endpoint over TLS), JIT-provisions alice, sets the session,
    #    and 302s to /app/<slug>. urllib follows the whole chain; a SUCCESSFUL
    #    login lands on the authenticated /app, a FAILED one stays on Keycloak or
    #    bounces to /sign_in.
    with op.open(urllib.request.Request(action, data=data), timeout=20) as r:
        final_url = r.geturl()
        final_status = r.status
    if "/app" not in final_url:
        fail(
            f"OIDC login did NOT land on the authenticated app "
            f"(status={final_status}, url={final_url}) — token exchange / JIT likely failed"
        )
    log(f"OIDC: callback → authenticated app at {final_url} ✓")
    log("OIDC e2e PASSED (alice JIT-provisioned + signed in)")


def main():
    log("waiting for portal + keycloak …")
    wait_for("portal", portal_ready)
    wait_for("keycloak", keycloak_ready)
    test_scim()
    test_oidc()
    log("ALL SSO e2e CHECKS PASSED ✓")


if __name__ == "__main__":
    main()
