// Command sso-e2e is the SSO end-to-end driver. It runs FROM THE HOST (via
// dev/keycloak/e2e/run.sh) against the published localhost ports — portal
// localhost:4010, Keycloak localhost:8443 — which is the exact path a host
// browser takes, so a green run proves the host-browser SSO flow works.
// Reads PORTAL_URL / KEYCLOAK_ISSUER / KEYCLOAK_CA / PROVIDER_ID /
// SCIM_TOKEN / KC_USER / KC_PASS / ALICE_KC_ID from the environment.
//
// Tests both halves against the seeded Keycloak IdentityProvider, and
// crucially their CONVERGENCE:
//
//  1. SCIM — provision alice, the real IdP user, keyed by her Keycloak id as
//     externalId (ALICE_KC_ID); plus a provision/read/deprovision lifecycle
//     on a throwaway user — all against /scim/v2 with the fixed dev bearer.
//  2. OIDC — the full auth-code login as alice through Keycloak's real login
//     page, landing back on emisar's /sign_in/sso/callback. Her OIDC `sub`
//     equals the SCIM externalId, so the login CONVERGES on the identity
//     SCIM just provisioned (decision 4) — it does NOT park her as an email
//     collision.
//
// Exit 0 on success, non-zero on any failure. Stdlib only. DEV ONLY. Lives
// in the never-shipped tools module (see tools/cmd/depgate/main.go for the
// module rule).
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

func logf(format string, args ...any) {
	fmt.Printf("[sso-e2e] "+format+"\n", args...)
}

func fail(format string, args ...any) {
	logf("FAIL: "+format, args...)
	os.Exit(1)
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fail("required env %s is not set", key)
	}
	return v
}

// waitFor polls fn every two seconds until it returns true (readiness probe:
// any error retries).
func waitFor(name string, fn func() (bool, error)) {
	var last error
	for i := 0; i < 60; i++ {
		ok, err := fn()
		if err == nil && ok {
			logf("%s ready", name)
			return
		}
		if err != nil {
			last = err
		}
		time.Sleep(2 * time.Second)
	}
	fail("%s not ready after 120s (last error: %v)", name, last)
}

type driver struct {
	portal, issuer, providerID, scimToken string
	kcUser, kcPass, aliceKCID             string
	client                                *http.Client
}

// scim performs one SCIM call and returns the status plus the decoded body
// (an empty map for an empty body) — non-2xx responses return normally, like
// a browser IdP would see them.
func (d *driver) scim(method, path string, body any) (int, map[string]any) {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			fail("marshaling SCIM body: %v", err)
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, d.portal+path, reader)
	if err != nil {
		fail("building SCIM request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+d.scimToken)
	req.Header.Set("Content-Type", "application/scim+json")
	req.Header.Set("Accept", "application/scim+json")
	resp, err := d.client.Do(req)
	if err != nil {
		fail("SCIM %s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		fail("SCIM %s %s read: %v", method, path, err)
	}
	decoded := map[string]any{}
	if len(raw) > 0 {
		// A non-JSON error body still surfaces via the status assertion at
		// the call site; the decode failure itself isn't the signal.
		_ = json.Unmarshal(raw, &decoded)
	}
	return resp.StatusCode, decoded
}

func (d *driver) testSCIM() {
	// Real directory sync: provision alice — the actual IdP user — keyed by
	// her Keycloak id as externalId. Her OIDC login below carries the same
	// value as `sub`, so the two converge on ONE identity (decision 4);
	// testOIDC proves it.
	logf("SCIM: provisioning alice@northstar.example (externalId=%s) …", d.aliceKCID)
	alice := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		"userName":   "alice@northstar.example",
		"name":       map[string]string{"givenName": "Alice", "familyName": "Admin"},
		"emails":     []map[string]any{{"value": "alice@northstar.example", "primary": true}},
		"active":     true,
		"externalId": d.aliceKCID,
	}
	status, resp := d.scim(http.MethodPost, "/scim/v2/Users", alice)
	if status != 200 && status != 201 {
		fail("SCIM provision of alice returned %d: %v", status, resp)
	}
	if resp["id"] == nil || resp["id"] == "" {
		fail("SCIM provision of alice missing id: %v", resp)
	}
	logf("SCIM: alice provisioned id=%v active=%v ✓", resp["id"], resp["active"])

	// Deprovision lifecycle on a throwaway (carol) — exercises active:false →
	// suspended WITHOUT deactivating alice before her OIDC login.
	logf("SCIM: provisioning carol@northstar.example (deprovision lifecycle) …")
	carol := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		"userName":   "carol@northstar.example",
		"name":       map[string]string{"givenName": "Carol", "familyName": "SCIM"},
		"emails":     []map[string]any{{"value": "carol@northstar.example", "primary": true}},
		"active":     true,
		"externalId": "kc-carol-1",
	}
	status, resp = d.scim(http.MethodPost, "/scim/v2/Users", carol)
	if status != 200 && status != 201 {
		fail("SCIM create returned %d: %v", status, resp)
	}
	uid, _ := resp["id"].(string)
	if uid == "" {
		fail("SCIM create missing id: %v", resp)
	}
	logf("SCIM: carol created id=%s active=%v ✓", uid, resp["active"])

	status, resp = d.scim(http.MethodGet, "/scim/v2/Users/"+uid, nil)
	if status != 200 || resp["active"] != true {
		fail("SCIM read-after-create unexpected: %d %v", status, resp)
	}
	logf("SCIM: read back active=true ✓")

	logf("SCIM: deprovisioning carol (active:false) …")
	patch := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{{"op": "replace", "path": "active", "value": false}},
	}
	status, resp = d.scim(http.MethodPatch, "/scim/v2/Users/"+uid, patch)
	if status != 200 && status != 204 {
		fail("SCIM deprovision returned %d: %v", status, resp)
	}

	status, resp = d.scim(http.MethodGet, "/scim/v2/Users/"+uid, nil)
	if status == 200 && resp["active"] != false {
		fail("SCIM user still active after deprovision: %v", resp)
	}
	logf("SCIM: deprovision confirmed ✓")
	logf("SCIM e2e PASSED")
}

var loginActionRe = regexp.MustCompile(`action="([^"]*login-actions/authenticate[^"]*)"`)

func (d *driver) testOIDC() {
	logf("OIDC: auth-code login as alice …")

	// 1) begin → portal 302 to Keycloak → Keycloak login page (the client
	//    follows the 302 chain; the cookie jar carries both sessions).
	resp, err := d.client.Get(d.portal + "/sign_in/sso/" + d.providerID)
	if err != nil {
		fail("begin request: %v", err)
	}
	loginHTML, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		fail("reading login page: %v", err)
	}
	loginURL := resp.Request.URL.String()
	if !strings.HasPrefix(loginURL, d.issuer) {
		fail("begin did not reach the Keycloak issuer (got %s) — discovery/TLS-trust failed", loginURL)
	}
	logf("OIDC: portal discovered Keycloak over TLS + redirected to login — trust OK ✓")

	// 2) parse the Keycloak login-form action + POST alice's credentials.
	m := loginActionRe.FindSubmatch(loginHTML)
	if m == nil {
		fail("could not find the Keycloak login form action")
	}
	action := html.UnescapeString(string(m[1]))
	form := url.Values{"username": {d.kcUser}, "password": {d.kcPass}, "credentialId": {""}}

	// 3) POST → Keycloak 302 back to the portal callback → portal exchanges
	//    the code (token endpoint over TLS), resolves alice's `sub` to the
	//    identity SCIM provisioned (sub == externalId), sets the session, and
	//    302s to /app/<slug>. The client follows the whole chain; a
	//    SUCCESSFUL login lands on the authenticated /app. If the sub did NOT
	//    converge on the SCIM identity, alice's existing email would collide
	//    and the login would PARK (no /app) — landing on /app is the
	//    convergence proof.
	resp, err = d.client.PostForm(action, form)
	if err != nil {
		fail("posting Keycloak credentials: %v", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	finalURL := resp.Request.URL.String()
	if !strings.Contains(finalURL, "/app") {
		fail("OIDC login did NOT land on the authenticated app (status=%d, url=%s) — "+
			"token exchange failed, or alice's sub did not converge on her SCIM identity and she was parked",
			resp.StatusCode, finalURL)
	}
	logf("OIDC: callback → authenticated app at %s ✓", finalURL)
	logf("OIDC e2e PASSED (alice signed in — converged on her SCIM-provisioned identity)")
}

func main() {
	d := &driver{
		portal:     mustEnv("PORTAL_URL"),
		issuer:     mustEnv("KEYCLOAK_ISSUER"),
		providerID: mustEnv("PROVIDER_ID"),
		scimToken:  mustEnv("SCIM_TOKEN"),
		kcUser:     mustEnv("KC_USER"),
		kcPass:     mustEnv("KC_PASS"),
		// alice's PINNED Keycloak id (dev/keycloak/realm.json). Keycloak
		// issues it as the OIDC `sub`, and we POST it as the SCIM externalId —
		// so directory sync and login resolve to one identity (decision 4)
		// instead of parking her as a collision.
		aliceKCID: mustEnv("ALICE_KC_ID"),
	}

	// Trust the dev CA for HTTPS calls to Keycloak (the portal trusts the
	// same CA via update-ca-certificates → :public_key.cacerts_get/0).
	caPEM, err := os.ReadFile(mustEnv("KEYCLOAK_CA"))
	if err != nil {
		fail("reading KEYCLOAK_CA: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		fail("KEYCLOAK_CA contains no usable certificate")
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		fail("cookie jar: %v", err)
	}
	d.client = &http.Client{
		Timeout: 20 * time.Second,
		Jar:     jar,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool},
		},
	}

	logf("waiting for portal + keycloak …")
	waitFor("portal", func() (bool, error) {
		resp, err := d.client.Get(d.portal + "/healthz")
		if err != nil {
			return false, err
		}
		defer resp.Body.Close()
		io.Copy(io.Discard, resp.Body)
		return resp.StatusCode == 200, nil
	})
	waitFor("keycloak", func() (bool, error) {
		resp, err := d.client.Get(d.issuer + "/.well-known/openid-configuration")
		if err != nil {
			return false, err
		}
		defer resp.Body.Close()
		var cfg struct {
			Issuer string `json:"issuer"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
			return false, err
		}
		return cfg.Issuer == d.issuer, nil
	})

	d.testSCIM()
	d.testOIDC()
	logf("ALL SSO e2e CHECKS PASSED ✓")
}
