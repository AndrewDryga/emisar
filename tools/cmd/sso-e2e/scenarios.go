package main

// The SCIM surface an IdP actually drives, exercised against the real Keycloak
// stack: discovery, the bearer boundary, group and user lifecycle, operation
// ordering, input bounds, and the group→role mapping that turns a directory
// push into privilege here.
//
// Assertions that a protocol surface cannot see — a recomputed role, a revoked
// session — go through `rpc`, which runs Elixir inside the release the same way
// an operator would on a box.

import (
	"net/http"
	"net/url"
	"os/exec"
	"strings"
)

// filterPath builds a SCIM list URL with the filter properly escaped — a raw
// `displayName eq "x"` in a request line is not a URL, and the 400 it earns
// says nothing about the server.
func filterPath(resource, filter string) string {
	return "/scim/v2/" + resource + "?filter=" + url.QueryEscape(filter)
}

// rpc evaluates an Elixir expression inside the running portal and returns its
// trimmed stdout. The expression must print what it wants asserted.
func (d *driver) rpc(expr string) string {
	command := strings.Fields(mustEnv("PORTAL_RPC"))
	args := append(command[1:], expr)
	out, err := exec.Command(command[0], args...).CombinedOutput()
	if err != nil {
		fail("rpc %q: %v\n%s", expr, err, out)
	}
	return strings.TrimSpace(string(out))
}

// roleOf reads a member's CURRENT role in the demo account — the thing a
// group→role mapping is for.
func (d *driver) roleOf(externalID string) string {
	return d.rpc(`
	  alias Emisar.{Accounts, Repo, SSO}
	  identity =
	    SSO.UserIdentity.Query.not_deleted()
	    |> SSO.UserIdentity.Query.by_provider_and_scim_identity("` + d.providerID + `", "` + externalID + `")
	    |> Repo.peek()
	  case identity && Accounts.peek_sync_membership(identity.account_id, identity.user_id) do
	    nil -> IO.puts("none")
	    membership -> IO.puts(to_string(membership.role))
	  end`)
}

func (d *driver) testDiscovery() {
	logf("discovery: ServiceProviderConfig, ResourceTypes, Schemas …")

	status, resp := d.scim(http.MethodGet, "/scim/v2/ServiceProviderConfig", nil)
	if status != 200 || resp["patch"] == nil {
		fail("ServiceProviderConfig: %d %v", status, resp)
	}

	// Groups have a full route set; a client that decides what to push by
	// reading discovery must be told they exist.
	status, resp = d.scim(http.MethodGet, "/scim/v2/ResourceTypes", nil)
	if status != 200 {
		fail("ResourceTypes: %d %v", status, resp)
	}
	advertised := map[string]bool{}
	for _, raw := range resp["Resources"].([]any) {
		advertised[raw.(map[string]any)["id"].(string)] = true
	}
	if !advertised["User"] || !advertised["Group"] {
		fail("ResourceTypes must advertise User AND Group, got %v", advertised)
	}

	for _, id := range []string{"User", "Group"} {
		if status, _ := d.scim(http.MethodGet, "/scim/v2/ResourceTypes/"+id, nil); status != 200 {
			fail("ResourceTypes/%s: %d", id, status)
		}
	}
	for _, urn := range []string{
		"urn:ietf:params:scim:schemas:core:2.0:User",
		"urn:ietf:params:scim:schemas:core:2.0:Group",
	} {
		if status, _ := d.scim(http.MethodGet, "/scim/v2/Schemas/"+urn, nil); status != 200 {
			fail("Schemas/%s: %d", urn, status)
		}
	}
	logf("discovery: both resources advertised and fetchable ✓")
}

func (d *driver) testBearerBoundary() {
	logf("bearer: unauthenticated and wrong-token calls …")

	for name, token := range map[string]string{
		"no bearer":     "",
		"garbage":       "ems-not-a-real-token-at-all",
		"right prefix":  "ems-" + strings.Repeat("a", 40),
		"other scheme":  "Basic " + d.scimToken,
		"empty  bearer": " ",
	} {
		req, err := http.NewRequest(http.MethodGet, d.portal+"/scim/v2/Users", nil)
		if err != nil {
			fail("building %s request: %v", name, err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := d.client.Do(req)
		if err != nil {
			fail("%s: %v", name, err)
		}
		resp.Body.Close()
		if resp.StatusCode != 401 {
			fail("%s should be 401, got %d", name, resp.StatusCode)
		}
	}
	logf("bearer: every unauthorized shape refused with 401 ✓")
}

func (d *driver) testGroupLifecycle() {
	logf("groups: empty group, members, replace, delta, rename …")

	// A group with no members must EXIST — this is the 201-then-404 lifecycle
	// violation, and the probe an IdP makes before every push depends on it.
	empty := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-empty",
		"displayName": "E2E Empty",
		"members":     []any{},
	}
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Groups", empty); status != 201 && status != 200 {
		fail("empty group create: %d %v", status, resp)
	}
	status, resp := d.scim(http.MethodGet, "/scim/v2/Groups/e2e-empty", nil)
	if status != 200 {
		fail("empty group must be readable right after create, got %d %v", status, resp)
	}
	logf("groups: an empty group exists and round-trips ✓")

	// The displayName probe Entra sends before every push.
	status, resp = d.scim(http.MethodGet, filterPath("Groups", `displayName eq "E2E Empty"`), nil)
	if status != 200 || resp["totalResults"].(float64) != 1 {
		fail("displayName probe should find exactly the group: %d %v", status, resp)
	}
	logf("groups: displayName probe finds it ✓")

	// A group naming someone the directory has not provisioned yet survives
	// until they arrive — SCIM does not order Users before Groups.
	early := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-early",
		"displayName": "E2E Early",
		"members":     []map[string]any{{"value": "e2e-latecomer"}},
	}
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Groups", early); status != 201 && status != 200 {
		fail("early group create: %d %v", status, resp)
	}
	if status, _ := d.scim(http.MethodGet, "/scim/v2/Groups/e2e-early", nil); status != 200 {
		fail("a group pushed before its members must survive, got %d", status)
	}
	logf("groups: a group pushed before its members survives ✓")

	// A rename batched with a membership change must apply BOTH.
	batch := map[string]any{
		"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{
			{"op": "replace", "path": "displayName", "value": "E2E Renamed"},
			{"op": "add", "path": "members", "value": []map[string]any{{"value": d.aliceKCID}}},
		},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Groups/e2e-empty", batch); status != 200 {
		fail("batched rename+members: %d %v", status, resp)
	}
	status, resp = d.scim(http.MethodGet, "/scim/v2/Groups/e2e-empty", nil)
	if status != 200 || resp["displayName"] != "E2E Renamed" {
		fail("rename half of the batch did not apply: %d %v", status, resp)
	}
	if len(resp["members"].([]any)) != 1 {
		fail("member half of the batch did not apply: %v", resp["members"])
	}
	logf("groups: a batched rename + member add applies both halves ✓")

	// Wire order decides: replace to [alice], then remove alice, ends empty.
	ordered := map[string]any{
		"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{
			{"op": "replace", "path": "members", "value": []map[string]any{{"value": d.aliceKCID}}},
			{"op": "remove", "path": "members", "value": []map[string]any{{"value": d.aliceKCID}}},
		},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Groups/e2e-empty", ordered); status != 200 {
		fail("ordered member ops: %d %v", status, resp)
	}
	status, resp = d.scim(http.MethodGet, "/scim/v2/Groups/e2e-empty", nil)
	if members := resp["members"].([]any); status != 200 || len(members) != 0 {
		fail("a remove AFTER a replace must win: %d, group still has %v", status, members)
	}
	logf("groups: the last operation on a member wins ✓")

	// A pathless replace carrying BOTH attributes must apply both. Treating any
	// such map containing displayName as a rename dropped `members` silently —
	// the endpoint answered 200 while the people the directory had just removed
	// kept the group's mapped role.
	multi := map[string]any{
		"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{{
			"op": "replace",
			"value": map[string]any{
				"displayName": "E2E Both",
				"members":     []map[string]any{{"value": d.aliceKCID}},
			},
		}},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Groups/e2e-empty", multi); status != 200 {
		fail("pathless multi-attribute replace: %d %v", status, resp)
	}
	status, resp = d.scim(http.MethodGet, "/scim/v2/Groups/e2e-empty", nil)
	if status != 200 || resp["displayName"] != "E2E Both" {
		fail("the rename half was dropped: %d %v", status, resp)
	}
	if len(resp["members"].([]any)) != 1 {
		fail("the members half was dropped: %v", resp["members"])
	}
	logf("groups: a pathless replace naming both attributes applies both ✓")

	// DELETE removes the resource; a group we never saw is not found.
	if status, _ := d.scim(http.MethodDelete, "/scim/v2/Groups/e2e-early", nil); status != 204 {
		fail("DELETE should answer 204, got %d", status)
	}
	if status, _ := d.scim(http.MethodGet, "/scim/v2/Groups/e2e-early", nil); status != 404 {
		fail("a deleted group must be gone, GET answered %d", status)
	}
	if status, _ := d.scim(http.MethodDelete, "/scim/v2/Groups/e2e-never", nil); status != 404 {
		fail("deleting a group we never saw must be 404, got %d", status)
	}
	logf("groups: DELETE removes the resource and refuses an unknown one ✓")

	// PUT is a whole-set replace bound to the PATH id, never the body's.
	crossed := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-crossed",
		"displayName": "Should Not Move",
		"members":     []map[string]any{{"value": d.aliceKCID}},
	}
	if status, resp := d.scim(http.MethodPut, "/scim/v2/Groups/e2e-empty", crossed); status != 200 {
		fail("PUT: %d %v", status, resp)
	}
	// The body named e2e-crossed; it must not have been created or touched.
	if status, _ := d.scim(http.MethodGet, "/scim/v2/Groups/e2e-crossed", nil); status != 404 {
		fail("PUT must not touch the group named only in the BODY, GET answered %d", status)
	}
	logf("groups: PUT writes the path's group, not the body's ✓")
}

func (d *driver) testRoleMapping() {
	logf("mapping: a directory group grants a role …")

	// Map the group to :admin the way the console does, then push alice into it.
	d.rpc(`
	  alias Emisar.{Repo, SSO}
	  provider = Repo.peek(SSO.IdentityProvider.Query.by_id(SSO.IdentityProvider.Query.all(), "` + d.providerID + `"))
	  {:ok, _} =
	    SSO.GroupRoleMapping.Changeset.create(provider.account_id, provider.id, %{
	      external_group_id: "e2e-privileged",
	      role: :admin
	    })
	    |> Repo.insert(on_conflict: :nothing)
	  IO.puts("mapped")`)

	before := d.roleOf(d.aliceKCID)
	logf("mapping: alice starts as %s", before)

	push := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-privileged",
		"displayName": "E2E Privileged",
		"members":     []map[string]any{{"value": d.aliceKCID}},
	}
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Groups", push); status != 201 && status != 200 {
		fail("privileged group push: %d %v", status, resp)
	}
	if role := d.roleOf(d.aliceKCID); role != "admin" {
		fail("a mapped group must grant its role, alice is %q", role)
	}
	logf("mapping: the push promoted alice to admin ✓")

	// Taking her out returns her to the connection default — the demotion an
	// offboard-from-a-group is supposed to produce.
	empty := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-privileged",
		"displayName": "E2E Privileged",
		"members":     []any{},
	}
	if status, resp := d.scim(http.MethodPut, "/scim/v2/Groups/e2e-privileged", empty); status != 200 {
		fail("emptying the privileged group: %d %v", status, resp)
	}
	if role := d.roleOf(d.aliceKCID); role != "operator" {
		fail("leaving the group must reset to the connection default, alice is %q", role)
	}
	logf("mapping: leaving the group demoted her to the default ✓")
}

func (d *driver) testUserOrdering() {
	logf("users: PATCH ordering, reconcile, and reactivation …")

	dave := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		"userName":   "dave@northstar.example",
		"emails":     []map[string]any{{"value": "dave@northstar.example", "primary": true}},
		"active":     true,
		"externalId": "e2e-dave",
	}
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Users", dave); status != 201 && status != 200 {
		fail("dave create: %d %v", status, resp)
	}

	// An IdP that reinstates and then offboards in one request means the
	// offboard. Taking the first operation read the batch backwards.
	both := map[string]any{
		"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{
			{"op": "replace", "path": "active", "value": true},
			{"op": "replace", "path": "active", "value": false},
		},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Users/e2e-dave", both); status != 200 {
		fail("ordered active ops: %d %v", status, resp)
	}
	status, resp := d.scim(http.MethodGet, "/scim/v2/Users/e2e-dave", nil)
	if status != 200 || resp["active"] != false {
		fail("the LAST active operation must win: %v", resp)
	}
	logf("users: the last `active` operation wins ✓")

	// A re-POST reconciles to the state the directory just asserted — some IdPs
	// re-create rather than PATCH, and hearing "active" when it said "inactive"
	// silently undid an offboarding.
	dave["active"] = false
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Users", dave); status != 200 && status != 201 {
		fail("re-POST: %d %v", status, resp)
	}
	if status, resp := d.scim(http.MethodGet, "/scim/v2/Users/e2e-dave", nil); status != 200 ||
		resp["active"] != false {
		fail("a re-POST carrying active:false must not reinstate: %d %v", status, resp)
	}
	logf("users: a duplicate create reconciles to the posted state ✓")

	// Reactivation restores access.
	on := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{{"op": "replace", "path": "active", "value": true}},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Users/e2e-dave", on); status != 200 {
		fail("reactivate: %d %v", status, resp)
	}
	if status, resp := d.scim(http.MethodGet, "/scim/v2/Users/e2e-dave", nil); status != 200 ||
		resp["active"] != true {
		fail("reactivation did not take: %d %v", status, resp)
	}
	logf("users: reactivation restores the member ✓")

	// The handle a create returns is the one a filter finds. When it was not,
	// an IdP re-created the same person on every cycle.
	status, resp = d.scim(http.MethodGet, filterPath("Users", `userName eq "dave@northstar.example"`), nil)
	if status != 200 || resp["totalResults"].(float64) != 1 {
		fail("userName probe must find the user it just created: %d %v", status, resp)
	}
	status, resp = d.scim(http.MethodGet, filterPath("Users", `externalId eq "e2e-dave"`), nil)
	if status != 200 || resp["totalResults"].(float64) != 1 {
		fail("externalId probe: %d %v", status, resp)
	}
	logf("users: both probes find what the create returned ✓")
}

func (d *driver) testBounds() {
	logf("bounds: oversized operation lists and member sets …")

	operations := make([]map[string]any, 0, 101)
	for i := 0; i < 101; i++ {
		operations = append(operations, map[string]any{
			"op": "replace", "path": "active", "value": false,
		})
	}
	body := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": operations,
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Users/e2e-dave", body); status != 400 {
		fail("an over-cap operation list must be refused, got %d %v", status, resp)
	}

	members := make([]map[string]any, 0, 5001)
	for i := 0; i < 5001; i++ {
		members = append(members, map[string]any{"value": "filler"})
	}
	group := map[string]any{
		"schemas":     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"externalId":  "e2e-huge",
		"displayName": "E2E Huge",
		"members":     members,
	}
	if status, resp := d.scim(http.MethodPost, "/scim/v2/Groups", group); status != 400 {
		fail("an over-cap member set must be refused, got %d %v", status, resp)
	}
	logf("bounds: both caps refuse with 400 ✓")
}

// testOffboardingEndsAccess proves the promise the docs make: an offboard in the
// directory revokes emisar access, not merely the ability to start a new login.
func (d *driver) testOffboardingEndsAccess() {
	logf("offboarding: a deprovision ends the session it granted …")

	sessions := func() string {
		return d.rpc(`
		  alias Emisar.{Auth, Repo, SSO}
		  identity =
		    SSO.UserIdentity.Query.not_deleted()
		    |> SSO.UserIdentity.Query.by_provider_and_scim_identity("` + d.providerID + `", "` + d.aliceKCID + `")
		    |> Repo.peek()
		  count =
		    Auth.UserToken.Query.by_user_id(identity.user_id)
		    |> Auth.UserToken.Query.by_context("session")
		    |> Repo.all()
		    |> length()
		  IO.puts(to_string(count))`)
	}

	before := sessions()
	if before == "0" {
		fail("alice should hold a session from the OIDC login, found none")
	}
	logf("offboarding: alice holds %s session(s) before the deprovision", before)

	patch := map[string]any{
		"schemas":    []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
		"Operations": []map[string]any{{"op": "replace", "path": "active", "value": false}},
	}
	if status, resp := d.scim(http.MethodPatch, "/scim/v2/Users/"+d.aliceKCID, patch); status != 200 {
		fail("deprovisioning alice: %d %v", status, resp)
	}
	if after := sessions(); after != "0" {
		fail("the deprovision must revoke her sessions, %s remain", after)
	}
	logf("offboarding: her sessions are gone ✓")

	// And she cannot start a new one: the membership is suspended.
	if role := d.roleOf(d.aliceKCID); role == "none" {
		fail("deprovisioning must SUSPEND, never delete the member")
	}
	suspended := d.rpc(`
	  alias Emisar.{Accounts, Repo, SSO}
	  identity =
	    SSO.UserIdentity.Query.not_deleted()
	    |> SSO.UserIdentity.Query.by_provider_and_scim_identity("` + d.providerID + `", "` + d.aliceKCID + `")
	    |> Repo.peek()
	  membership = Accounts.peek_sync_membership(identity.account_id, identity.user_id)
	  IO.puts(to_string(not is_nil(membership.disabled_at)))`)
	if suspended != "true" {
		fail("the member should be suspended after a deprovision, got %q", suspended)
	}
	logf("offboarding: the member is suspended, not deleted ✓")
}
