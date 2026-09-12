package devtool

import (
	"strings"
	"testing"
)

// `capture docs` used to demand Keycloak for every run, including a re-shoot of
// a single Portal page, which a workspace without the hidden Keycloak TLS key
// can never satisfy. The selected shot names decide now, and they decide before
// a browser starts.
func TestCaptureDocsRequiresKeycloakOnlyForTheShotsThatDriveIt(t *testing.T) {
	portal := "http://127.0.0.1:43659"
	for _, testCase := range []struct {
		name string
		// only is the shot selection after `capture docs`.
		only []string
		// keycloak is the URL Coop published for the service, empty when the
		// workspace never got one.
		keycloak  string
		portalURL string
		wantError string
	}{
		{
			// The route this exists for: one Portal page, no Keycloak in the box.
			// It gets past dependency loading and stops where every capture stops
			// without a browser profile to pin.
			name:      "a Portal shot needs no Keycloak",
			only:      []string{"policy-editor"},
			portalURL: portal,
			wantError: "the Keycloak certificate is missing",
		},
		{
			// loopFrames drive the product through BaseURL; captureLoopTake never
			// opens the admin console.
			name:      "an approval-loop frame needs no Keycloak",
			only:      []string{"loop-approval-pending"},
			portalURL: portal,
			wantError: "the Keycloak certificate is missing",
		},
		{
			name:      "a Keycloak shot still requires the service",
			only:      []string{"keycloak-client-secret"},
			portalURL: portal,
			wantError: "this command needs Keycloak",
		},
		{
			name:      "a mixed selection still requires the service",
			only:      []string{"policy-editor", "keycloak-client-scopes"},
			portalURL: portal,
			wantError: "this command needs Keycloak",
		},
		{
			name:      "the full capture still requires the service",
			portalURL: portal,
			wantError: "this command needs Keycloak",
		},
		{
			// An unknown name is resolved before any service is required, so a
			// typo reports the typo rather than a missing dependency — and no
			// browser is started for a run that would capture nothing.
			name:      "an unknown shot name fails before dependencies",
			only:      []string{"policy-editr"},
			wantError: `unknown docs shot "policy-editr"`,
		},
		{
			name:      "the Portal is still required",
			only:      []string{"policy-editor"},
			keycloak:  "https://localhost:30344",
			wantError: "this command needs Portal",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			app := serveWorkspace(t, map[workspaceDependency]string{
				needPortal:   testCase.portalURL,
				needKeycloak: testCase.keycloak,
			})
			err := app.Run(t.Context(), append([]string{"capture", "docs"}, testCase.only...))
			if err == nil || !strings.Contains(err.Error(), testCase.wantError) {
				t.Fatalf("capture docs %v error = %v, want one containing %q", testCase.only, err, testCase.wantError)
			}
		})
	}
}
