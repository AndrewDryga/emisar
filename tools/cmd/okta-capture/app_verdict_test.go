package main

import "testing"

// -cleanup deletes every application this rig recognizes as its own. It also
// RESUMES two applications rather than recreating them — the saved SCIM app by
// id, and the OIDC app by name (whose default is the bare word "emisar") — and
// both match the /emisar/ name filter. So a cleanup run deleted the two apps the
// next certification run signs in against.
//
// The user filter already carries a keeper for exactly this reason, added after
// the same accident nearly removed the tenant's only admin. This pins the
// application half, which had none. It lives in Go rather than in the browser
// script because this rig cannot be rehearsed: running it means mutating a real
// Okta org.
func TestAppVerdict(t *testing.T) {
	env := map[string]string{
		"OKTA_SCIM_APP_ID":   "0oa1saved",
		"OKTA_OIDC_APP_NAME": "emisar",
	}

	for _, tc := range []struct {
		name                     string
		id, label, settingsLabel string
		env                      map[string]string
		want                     string
	}{
		{"saved SCIM app is kept by id", "0oa1saved", "emisar SCIM", "", env, verdictKeep},
		{"OIDC app is kept by exact name", "0oa2other", "emisar", "", env, verdictKeep},
		{"a leftover of ours is deleted", "0oa3junk", "emisar docs capture", "", env, verdictDelete},
		{"ours by settings label", "0oa4junk", "untitled", "emisar probe", env, verdictDelete},
		{"someone else's app is spared", "0oa5theirs", "Workday", "", env, verdictSpare},

		// Without the ids the keeper cannot be identified, so the SCIM app falls
		// back to the name filter and is deleted. That is the old behaviour, and
		// it is why the ids must reach this function rather than being optional
		// decoration.
		{"no saved ids: the SCIM app is not protected", "0oa1saved", "emisar SCIM", "", map[string]string{}, verdictDelete},

		// An empty configured value must never turn into a wildcard that keeps
		// every unnamed row.
		{"blank name does not keep an unnamed app", "0oa6", "", "", map[string]string{"OKTA_OIDC_APP_NAME": ""}, verdictSpare},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := appVerdict(tc.id, tc.label, tc.settingsLabel, tc.env); got != tc.want {
				t.Errorf("appVerdict(%q, %q, %q) = %q, want %q",
					tc.id, tc.label, tc.settingsLabel, got, tc.want)
			}
		})
	}
}
