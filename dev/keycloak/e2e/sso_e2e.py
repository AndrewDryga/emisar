#!/usr/bin/env python3
"""
SSO end-to-end driver. Runs FROM THE HOST (via dev/keycloak/e2e/run.sh) against
the published localhost ports — portal localhost:4010, Keycloak localhost:8443 —
which is the exact path a host browser takes, so a green run proves the
host-browser SSO flow works. Reads PORTAL_URL / KEYCLOAK_ISSUER / KEYCLOAK_CA /
PROVIDER_ID / SCIM_TOKEN / KC_USER / KC_PASS / ALICE_KC_ID from the environment.

Tests both halves against the seeded Keycloak IdentityProvider, and crucially
their CONVERGENCE:

  1. SCIM  — provision alice, the real IdP user, keyed by her Keycloak id as
             externalId (ALICE_KC_ID); plus a provision/read/deprovision
             lifecycle on a throwaway user — all against /scim/v2 with the fixed
             dev bearer.
  2. OIDC  — the full auth-code login as alice through Keycloak's real login
             page, landing back on emisar's /sign_in/sso/callback. Her OIDC
             `sub` equals the SCIM externalId, so the login CONVERGES on the
             identity SCIM just provisioned (decision 4) — it does NOT park her
             as an email collision.

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
# alice's PINNED Keycloak id (dev/keycloak/realm.json). Keycloak issues it as the
# OIDC `sub`, and we POST it as the SCIM externalId — so directory sync and login
# resolve to one identity (decision 4) instead of parking her as a collision.
ALICE_KC_ID = os.environ["ALICE_KC_ID"]

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
    # Real directory sync: provision alice — the actual IdP user — keyed by her
    # Keycloak id as externalId. Her OIDC login below carries the same value as
    # `sub`, so the two converge on ONE identity (decision 4); test_oidc proves it.
    log(f"SCIM: provisioning alice@northstar.example (externalId={ALICE_KC_ID}) …")
    alice = {
        "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName": "alice@northstar.example",
        "name": {"givenName": "Alice", "familyName": "Admin"},
        "emails": [{"value": "alice@northstar.example", "primary": True}],
        "active": True,
        "externalId": ALICE_KC_ID,
    }
    status, resp = scim("POST", "/scim/v2/Users", alice)
    if status not in (200, 201):
        fail(f"SCIM provision of alice returned {status}: {resp}")
    if not resp.get("id"):
        fail(f"SCIM provision of alice missing id: {resp}")
    log(f"SCIM: alice provisioned id={resp.get('id')} active={resp.get('active')} ✓")

    # Deprovision lifecycle on a throwaway (carol) — exercises active:false →
    # suspended WITHOUT deactivating alice before her OIDC login.
    log("SCIM: provisioning carol@northstar.example (deprovision lifecycle) …")
    carol = {
        "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName": "carol@northstar.example",
        "name": {"givenName": "Carol", "familyName": "SCIM"},
        "emails": [{"value": "carol@northstar.example", "primary": True}],
        "active": True,
        "externalId": "kc-carol-1",
    }
    status, resp = scim("POST", "/scim/v2/Users", carol)
    if status not in (200, 201):
        fail(f"SCIM create returned {status}: {resp}")
    uid = resp.get("id")
    if not uid:
        fail(f"SCIM create missing id: {resp}")
    log(f"SCIM: carol created id={uid} active={resp.get('active')} ✓")

    status, resp = scim("GET", f"/scim/v2/Users/{uid}")
    if status != 200 or resp.get("active") is not True:
        fail(f"SCIM read-after-create unexpected: {status} {resp}")
    log("SCIM: read back active=true ✓")

    log("SCIM: deprovisioning carol (active:false) …")
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
    #    code (token endpoint over TLS), resolves alice's `sub` to the identity
    #    SCIM provisioned (sub == externalId), sets the session, and 302s to
    #    /app/<slug>. urllib follows the whole chain; a SUCCESSFUL login lands on
    #    the authenticated /app. If the sub did NOT converge on the SCIM identity,
    #    alice's existing email would collide and the login would PARK (no /app) —
    #    so landing on /app is the convergence proof.
    with op.open(urllib.request.Request(action, data=data), timeout=20) as r:
        final_url = r.geturl()
        final_status = r.status
    if "/app" not in final_url:
        fail(
            f"OIDC login did NOT land on the authenticated app "
            f"(status={final_status}, url={final_url}) — token exchange failed, or "
            f"alice's sub did not converge on her SCIM identity and she was parked"
        )
    log(f"OIDC: callback → authenticated app at {final_url} ✓")
    log("OIDC e2e PASSED (alice signed in — converged on her SCIM-provisioned identity)")


def main():
    log("waiting for portal + keycloak …")
    wait_for("portal", portal_ready)
    wait_for("keycloak", keycloak_ready)
    test_scim()
    test_oidc()
    log("ALL SSO e2e CHECKS PASSED ✓")


if __name__ == "__main__":
    main()
