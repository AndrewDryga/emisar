package main

import "testing"

// -flow inventory -cleanup deletes every object this rig recognizes as its own,
// against a real Entra tenant. The filter matched the registration form's name
// case-insensitively while claiming to own exactly what the form types, so an
// object someone else named "Emisar" was listed for deletion — the over-broad
// half of the mistake .agent/kb/rules/shared-capture-rigs-own-what-they-create.md
// records, whose other half hides leftovers.
//
// This lives in Go rather than being checked by running the rig because the rig
// cannot be rehearsed: running it means mutating the founder's tenant.
func TestAppVerdict(t *testing.T) {
	env := map[string]string{
		"ENTRA_CLIENT_ID":   "11111111-1111-1111-1111-111111111111",
		"ENTRA_SCIM_APP_ID": "22222222-2222-2222-2222-222222222222",
	}

	for _, tc := range []struct {
		name string
		row  graphRow
		env  map[string]string
		want string
	}{
		{"the walkthrough app is kept by id", graphRow{ID: "o1", AppID: env["ENTRA_CLIENT_ID"], DisplayName: "emisar"}, env, verdictKeep},
		{"the SCIM app is kept by id", graphRow{ID: "o2", AppID: env["ENTRA_SCIM_APP_ID"], DisplayName: "emisar directory sync certification"}, env, verdictKeep},
		{"a duplicate of ours is deleted", graphRow{ID: "o3", AppID: "a3", DisplayName: "emisar"}, env, verdictDelete},

		// The name is matched byte for byte. Graph returns displayName as it was
		// typed, so a different casing is a different object — someone else's.
		{"another casing is spared", graphRow{ID: "o4", AppID: "a4", DisplayName: "Emisar"}, env, verdictSpare},
		{"an upper-case name is spared", graphRow{ID: "o5", AppID: "a5", DisplayName: "EMISAR"}, env, verdictSpare},

		// Never a substring: these are the certification objects the provider runs
		// sign in and provision against, and a /emisar/ filter claimed both.
		{"the login certification object is spared", graphRow{ID: "o6", AppID: "a6", DisplayName: "emisar login certification"}, env, verdictSpare},
		{"the directory sync certification object is spared without its id", graphRow{ID: "o7", AppID: "a7", DisplayName: "emisar directory sync certification"}, env, verdictSpare},
		{"surrounding whitespace is not ours", graphRow{ID: "o8", AppID: "a8", DisplayName: " emisar"}, env, verdictSpare},
		{"someone else's app is spared", graphRow{ID: "o9", AppID: "a9", DisplayName: "Workday"}, env, verdictSpare},

		// Without the pinned ids the keepers fall back to the name filter, which is
		// why they must reach this function rather than being optional decoration.
		{"no saved ids: the walkthrough app is not protected", graphRow{ID: "o1", AppID: "a1", DisplayName: "emisar"}, map[string]string{}, verdictDelete},

		// An empty configured id must never turn into a wildcard that keeps every
		// row whose appId the listing did not carry.
		{"blank id does not keep an unidentified row", graphRow{ID: "o10", AppID: "", DisplayName: "emisar"}, map[string]string{"ENTRA_CLIENT_ID": ""}, verdictDelete},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := appVerdict(tc.row, tc.env); got != tc.want {
				t.Errorf("appVerdict(%+v) = %q, want %q", tc.row, got, tc.want)
			}
		})
	}
}
