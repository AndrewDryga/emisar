package browser

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

type DocsConfig struct {
	BaseURL     string
	KeycloakURL string
	Email       string
	Temp        string
	Static      string
	// Only limits the run to the named shots (all when empty) — fast iteration
	// on one capture without rewriting every committed image.
	Only []string
}

// shot is one docs screenshot: navigate Path, run any Clicks (reveal flows),
// then crop to Anchor at viewport Width, keep only the top TopCSS CSS pixels (or
// the header + first Rows RowSelector rows) when set, write Output.
type shot struct {
	Name     string
	Path     string
	Keycloak bool
	// Clicks run in order after navigation to reveal a flow before the crop.
	Clicks []string
	Anchor Anchor
	Width  int // viewport CSS width; 0 → defaultWidth
	TopCSS int // keep only the top N CSS pixels of the anchor (0 → whole anchor)
	// Rows + RowSelector cap a long list: hide every RowSelector row past the
	// first Rows before the shot, so the anchor shrinks to its header + those rows
	// and the tail falls away. RowSelector matches document-wide.
	Rows        int
	RowSelector string
	// NoBorder skips the 40px matte: for frames a component frames itself (the
	// console cast), and so overlay coordinates map 1:1 onto the image.
	NoBorder bool
	// Highlight outlines the controls the guide's step tells the operator to
	// touch, the way the vendor captures do. A console shot that shows a whole
	// form and marks nothing makes the reader hunt for the two fields the step
	// named; the crop says where to look, and this says what to look at.
	Highlight []string
	Output    string
}

// The docs measure is ~672px, so a shot displays at ~40% of a 1680px desktop
// capture — text turns illegible. Capturing narrower renders the same feature
// LARGER in the column, and a sub-xl width also lets the how-keys/what-is help
// rails (xl-gated on connect + agents) stack off-crop, since the docs prose
// beside the image already teaches them.
const (
	defaultWidth = 1680
	docsWidth    = 1120
)

// clickText clicks the first button/link/[phx-click] whose trimmed text equals label.
func clickText(label string) string {
	return fmt.Sprintf(`(()=>{const b=[...document.querySelectorAll('button,a,[phx-click]')].find(x=>x.textContent.trim()===%q);if(b){b.click();return true}return false})()`, label)
}

// clickRowLink clicks the first link matching a CSS selector whose row (or the
// link itself) contains the given text — list order is presentation, content is
// the contract (e.g. "the pending caddy.reload_config row", wherever it sorts).
func clickRowLink(selector, contains string) string {
	return fmt.Sprintf(`(()=>{const b=[...document.querySelectorAll(%q)].find(a=>((a.closest('li,tr')||a).textContent||'').includes(%q));if(b){b.click();return true}return false})()`, selector, contains)
}

// clickFirstEditLink opens a runbook's editor from the runbooks list.
const clickFirstEditLink = `(()=>{const a=document.querySelector('a[href*="/edit"]');if(a){a.click();return true}return false})()`

// collapseAuditFilters folds the audit facet drawer (it arrives expanded when
// the URL carries a filter). Self-verifying: reports success only once
// aria-expanded flips, so a click against the dead pre-connect render (which
// does nothing) is retried instead of trusted.
const collapseAuditFilters = `(()=>{const b=document.querySelector('button[phx-click="toggle_filters"]');if(!b)return false;if(b.getAttribute('aria-expanded')==='false')return true;b.click();return false})()`

// clickSSOConnection opens an SSO connection's detail page from the team page.
// selectEntraProvider configures the Add provider form the way /docs/sso#entra
// tells an operator to: Entra has no preset, so the kind is Generic OpenID
// Connect, and the identifier claim MUST be oid rather than the default sub.
// Both selects are LiveView-backed, so dispatch a change event after setting them.
// selectGoogleProvider picks the Google Workspace preset, whose issuer emisar
// fills in and LOCKS — the detail /docs/sso#google-workspace exists to show.
const selectGoogleProvider = `(()=>{const el=document.querySelector('select[name="provider[kind]"]');if(!el)return false;el.value='google_workspace';el.dispatchEvent(new Event('change',{bubbles:true}));return true})()`

const selectEntraProvider = `(()=>{const set=(sel,val)=>{const el=document.querySelector(sel);if(!el)return false;el.value=val;el.dispatchEvent(new Event('change',{bubbles:true}));return true};return set('select[name="provider[kind]"]','entra')})()`

// selectProviderKind picks a provider in the Add-provider form. Each guide's
// first step tells the reader to choose THEIR provider, so each guide's shot
// shows that provider chosen rather than a shared picture of someone else's.
func selectProviderKind(kind string) string {
	return fmt.Sprintf(`(()=>{const el=document.querySelector('select[name="provider[kind]"]');if(!el)return false;el.value=%q;el.dispatchEvent(new Event('change',{bubbles:true}));return true})()`, kind)
}

// chooseOidClaim runs as its OWN click, after the kind change has settled.
// Setting both in one snippet lost the claim: the kind's phx-change re-renders
// the form, and LiveView writes the server's value back over anything the
// browser had set — so the shot for "change Identifier claim to oid" showed sub.
const chooseOidClaim = `(()=>{const el=document.querySelector('select[name="provider[identifier_claim]"]');if(!el)return false;el.value='oid';el.dispatchEvent(new Event('change',{bubbles:true}));return true})()`

// showProductionHost rewrites the dev server's origin to the real product host in
// the RENDERED text only. A docs screenshot that reads localhost:43659 tells a
// customer nothing — emisar is not a self-hosted product — and the founder has
// flagged it before. Only the host is substituted; no value is invented.
const showProductionHost = `(()=>{const from=location.origin,to='https://emisar.dev';const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);const hits=[];while(walk.nextNode())if(walk.currentNode.nodeValue.includes(from))hits.push(walk.currentNode);hits.forEach(n=>n.nodeValue=n.nodeValue.split(from).join(to));document.querySelectorAll('[data-copy-text]').forEach(el=>el.setAttribute('data-copy-text',el.getAttribute('data-copy-text').split(from).join(to)));return true})()`

const clickSSOConnection = `(()=>{const a=[...document.querySelectorAll('a[href*="/settings/sso/"]')].find(x=>/\/settings\/sso\/[0-9a-f-]{8,}/.test(x.getAttribute('href')));if(a){a.click();return true}return false})()`

// openIdPGuide unfolds the connection's "Point your IdP at this connection"
// disclosure. It is a <details>, not a button, so clickText can't reach it —
// set `open` directly. The guide IS the setup instruction the docs page is
// teaching, so a shot of it collapsed shows the reader nothing.
const openIdPGuide = `(()=>{const s=[...document.querySelectorAll('summary')].find(x=>x.textContent.trim()==='Point your IdP at this connection');if(s&&s.parentElement){s.parentElement.open=true;return true}return false})()`

// docsShots — one entry per docs screenshot, each cropped to the one feature
// its page teaches, at docsWidth unless the content genuinely needs more room.
var docsShots = []shot{
	{Name: "policy-editor", Path: "/app/demo/policies", Anchor: Anchor{Heading: "Default policy", Climb: "section"}, Width: docsWidth, Output: "screenshots/policy-editor.webp"},
	{Name: "audit-view", Path: "/app/demo/audit?event_type[]=group:Run", Anchor: Anchor{Selector: "#audit-events"}, Width: 1280, Output: "screenshots/audit-view.webp"},
	{Name: "runner-fleet", Path: "/app/demo/runners", Anchor: Anchor{Selector: "#runners"}, Width: docsWidth, Output: "screenshots/runner-fleet.webp"},
	// The team page is a desktop 3-column layout: the member roster beside the
	// Security/SSO rail. Anchor the whole console content (#shell-canvas — the page
	// minus the nav rail) at a desktop width and keep the top TopCSS pixels: the
	// heading, the first roster rows, and the Security panel beside them. Anchoring
	// the roster column alone cropped a narrow, mobile-looking strip AND clipped its
	// header (chromedp mis-clips a tall element anchored partway down the page);
	// #shell-canvas is top-anchored, so it captures clean like the loop frames.
	{Name: "team-page", Path: "/app/demo/settings/team", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 820, Output: "screenshots/team-page.webp"},
	{Name: "runs", Path: "/app/demo/runs", Anchor: Anchor{Selector: "#runs"}, Width: 1280, Output: "screenshots/runs.webp"},
	{Name: "agents", Path: "/app/demo/agents", Anchor: Anchor{Selector: "#agents"}, Width: docsWidth, Output: "screenshots/agents.webp"},
	// Connect form: click a cloud client to reveal the connector fields, then crop
	// to the form panel — #connect-panel excludes the how-keys-work rail beside it.
	{Name: "connect-llm-agents", Path: "/app/demo/agents/connect", Clicks: []string{clickText("Claude.ai")}, Anchor: Anchor{Selector: "#connect-panel"}, Width: docsWidth, Output: "screenshots/connect-llm-agents.webp"},
	// Same connect panel with a LOCAL/CLI client selected — the bridge + key setup.
	{Name: "connect-cli-agents", Path: "/app/demo/agents/connect", Clicks: []string{clickText("Claude Code")}, Anchor: Anchor{Selector: "#connect-panel"}, Width: docsWidth, Output: "screenshots/connect-cli-agents.webp"},
	// Runbook editor: open a seeded runbook and crop to its ordered, gated steps —
	// what a runbook IS, not two list rows.
	{Name: "runbooks", Path: "/app/demo/runbooks", Clicks: []string{clickFirstEditLink}, Anchor: Anchor{Selector: "#runbook-steps"}, Width: docsWidth, Output: "screenshots/runbooks.webp"},
	{Name: "sso-directory-sync", Path: "/app/demo/settings/team", Clicks: []string{clickSSOConnection, openIdPGuide, showProductionHost}, Anchor: Anchor{Heading: "Directory sync (SCIM)", Climb: "section"}, Width: docsWidth, Output: "docs/sso/sso-directory-sync.webp"},
	// The two halves of group→role sync: the mappings an admin authors, and the
	// synced roster they land on. Both are seeded directory state (seeds.exs maps
	// two of three IdP groups, deliberately leaving one unmapped).
	// The step names the issuer and the two credential fields, so the shot is that
	// block — not the whole 3,788px form it used to be.
	{Name: "google-emisar-connection", Path: "/app/demo/settings/sso/new", Clicks: []string{selectGoogleProvider, showProductionHost}, Anchor: Anchor{Heading: "OIDC connection", Climb: "section"}, Highlight: []string{"Client ID", "Client secret"}, Width: docsWidth, Output: "docs/sso/google-emisar-connection.webp"},
	// Every guide's step 1 is "open Add provider and choose <provider>". One shot
	// each, showing that provider picked — the form is provider-aware, so a shared
	// picture of someone else's choice would be the wrong screen.
	{Name: "okta-emisar-add-provider", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("okta")}, Anchor: Anchor{Heading: "Provider type", Climb: "div"}, Highlight: []string{"Provider type"}, Width: docsWidth, Output: "docs/sso/okta-emisar-add-provider.webp"},
	{Name: "entra-emisar-add-provider", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("entra")}, Anchor: Anchor{Heading: "Provider type", Climb: "div"}, Highlight: []string{"Provider type"}, Width: docsWidth, Output: "docs/sso/entra-emisar-add-provider.webp"},
	{Name: "jumpcloud-emisar-add-provider", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("jumpcloud")}, Anchor: Anchor{Heading: "Provider type", Climb: "div"}, Highlight: []string{"Provider type"}, Width: docsWidth, Output: "docs/sso/jumpcloud-emisar-add-provider.webp"},
	{Name: "keycloak-emisar-add-provider", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("keycloak")}, Anchor: Anchor{Heading: "Provider type", Climb: "div"}, Highlight: []string{"Provider type"}, Width: docsWidth, Output: "docs/sso/keycloak-emisar-add-provider.webp"},
	{Name: "google-emisar-add-provider", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("google_workspace")}, Anchor: Anchor{Heading: "Provider type", Climb: "div"}, Highlight: []string{"Provider type"}, Width: docsWidth, Output: "docs/sso/google-emisar-add-provider.webp"},

	// "Paste the values back into emisar" — the fields the step names, outlined.
	// The guide told the reader which values to carry and then showed them nothing.
	{Name: "jumpcloud-emisar-credentials", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("jumpcloud"), showProductionHost}, Anchor: Anchor{Heading: "OIDC connection", Climb: "section"}, Highlight: []string{"Client ID", "Client secret"}, Width: docsWidth, Output: "docs/sso/jumpcloud-emisar-credentials.webp"},
	{Name: "okta-emisar-credentials", Path: "/app/demo/settings/sso/new", Clicks: []string{selectProviderKind("okta"), showProductionHost}, Anchor: Anchor{Heading: "OIDC connection", Climb: "section"}, Highlight: []string{"Issuer URL", "Client ID", "Client secret"}, Width: docsWidth, Output: "docs/sso/okta-emisar-credentials.webp"},

	// The step names ONE control — Identifier claim — so the shot is that field and
	// its explanation, outlined. It used to be the entire 3,290px form, which shows
	// the reader everything and points at nothing.
	{Name: "entra-emisar-connection", Path: "/app/demo/settings/sso/new", Clicks: []string{selectEntraProvider, chooseOidClaim, showProductionHost}, Anchor: Anchor{Heading: "Identifier claim", Climb: "div.sm\\:col-span-2"}, Highlight: []string{"Identifier claim"}, Width: docsWidth, Output: "docs/sso/entra-emisar-connection.webp"},
	{Name: "scim-group-role-mapping", Path: "/app/demo/settings/team", Clicks: []string{clickSSOConnection}, Anchor: Anchor{Heading: "Role mapping", Climb: "section"}, Width: docsWidth, Output: "docs/sso/scim-group-role-mapping.webp"},
	{Name: "scim-synced-users", Path: "/app/demo/settings/team", Clicks: []string{clickSSOConnection}, Anchor: Anchor{Heading: "Synced users", Climb: "section"}, Width: docsWidth, Output: "docs/sso/scim-synced-users.webp"},
}

// keycloakShots are the customer-visible steps in Keycloak's OIDC client flow.
// captureKeycloakGuide drives them in one isolated admin-console session so the
// unsaved create-client form never leaves an extra client behind, while the
// seeded emisar-portal client supplies the masked secret and assigned scopes.
var keycloakShots = []shot{
	{Name: "keycloak-client-general", Keycloak: true, Anchor: Anchor{Selector: "#kc-main-content-page-container form"}, Highlight: []string{"Client type", "Client ID"}, Width: docsWidth, Output: "docs/sso/keycloak-client-general.webp"},
	{Name: "keycloak-client-capabilities", Keycloak: true, Anchor: Anchor{Selector: `[data-testid="capability-config-form"]`}, Highlight: []string{"Client authentication", "Standard flow", "Require PKCE", "PKCE Method"}, Width: docsWidth, Output: "docs/sso/keycloak-client-capabilities.webp"},
	{Name: "keycloak-client-redirect", Keycloak: true, Anchor: Anchor{Selector: "#kc-main-content-page-container form"}, Highlight: []string{`css:[data-testid="redirectUris0"]`}, Width: docsWidth, Output: "docs/sso/keycloak-client-redirect.webp"},
	{Name: "keycloak-client-secret", Keycloak: true, Anchor: Anchor{Selector: `#kc-main-content-page-container section[role="tabpanel"]`}, Highlight: []string{"Client Secret"}, Width: docsWidth, TopCSS: 355, Output: "docs/sso/keycloak-client-secret.webp"},
	{Name: "keycloak-client-scopes", Keycloak: true, Anchor: Anchor{Selector: `table[aria-label="Client scopes"]`}, Highlight: []string{"row:email", "row:profile"}, Width: docsWidth, Output: "docs/sso/keycloak-client-scopes.webp"},
}

// loopFrames are the /security approval-loop cast frames. They are NOT
// navigate-and-crop shots: captureLoopTake drives the REAL product loop — in
// an isolated session signed in as Jordan, it opens the seeded pending
// caddy.reload_config request (agent-initiated, Maya via Claude), types the
// decision note, clicks Approve and send, waits for the live edge-fra-01
// runner to execute (the dev runner image stubs `caddy`, so the reload exits
// 0 with believable output), and photographs each stage — so every frame,
// transition, and audit row is the actual product doing the actual thing.
//
// #shell-canvas is the console page without the nav rail; TopCSS keeps every
// frame the same 1280x1180 box (the player windows it to 1280x860 and pans) so the cast can crossfade without reflow.
//
// Preconditions (the take verifies and SKIPs loudly otherwise):
//   - a fresh `./run reset --seed` with EMISAR_DEV_FIXED_ENROLLMENT_KEY set,
//     then a RESTART of the dev server (seeded pending approvals expire 24h
//     after seeding, the take consumes one per run, and a DB recreate under a
//     running server can poison Postgrex's type cache);
//   - a live edge-fra-01 runner adopted by this portal: the dev runner image
//     with EMISAR_URL pointed at this workspace, the fixed dev enrollment
//     key, and dev/runner-fixtures/bin mounts (incl. the caddy stub).
//     RECREATE the container after a reseed (docker rm -f + docker run — a
//     fresh /var/lib/emisar re-enrolls); a restarted container presents its
//     old token, gets a 401 from the fresh DB, and exits.
var loopFrames = []shot{
	{Name: "loop-approval-pending", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Output: "screenshots/loop/approval-pending.webp"},
	{Name: "loop-approval-note", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Output: "screenshots/loop/approval-note.webp"},
	{Name: "loop-approval-approved", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Output: "screenshots/loop/approval-approved.webp"},
	{Name: "loop-run-success", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Output: "screenshots/loop/run-success.webp"},
	// The Run + Approval groups together are the loop's trail; the folded
	// drawer still narrates them ("Filters — Type: …"), so the narrowing
	// stays visible while the frame is the timeline itself.
	{Name: "loop-audit-trail", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Rows: 11, RowSelector: "#audit-events li", Output: "screenshots/loop/audit-trail.webp"},
	// The closing beat: the take clicks the loop's own "Run succeeded" row and
	// photographs the audit event detail — the forensic close-up (actor,
	// target, request id, payload) one click deep.
	{Name: "loop-audit-event", Anchor: Anchor{Selector: "#shell-canvas"}, Width: 1280, TopCSS: 1180, NoBorder: true, Output: "screenshots/loop/audit-event.webp"},
}

// The note Jordan types during the take — it becomes the decision_reason on
// the real request, so it must read like an operator wrote it.
const loopDecisionNote = "validated config, active connections drained, deploy window open"

// loopTargets reports the cast's cursor/spotlight anchors as percentages of
// the captured frame — paste the printed JSON into the console_cast frame
// attrs on security.html.heex after a re-capture, so the overlay cursor and
// spotlights keep landing on the real controls. The frame's content height is
// derived from the canvas WIDTH (width x TopCSS/1280 CSS): the capture crop is
// proportional, so this holds whatever viewport the capture browser really
// used (chromedp's emulation override is not reliably honored).
const loopTargets = `(()=>{const c=document.querySelector('#shell-canvas').getBoundingClientRect();
const frameH=c.width*1180/1280;
const point=(el)=>{if(!el)return null;const b=el.getBoundingClientRect();
return {x:Math.round((b.x+b.width/2-c.x)/c.width*1000)/10,y:Math.round((b.y+b.height/2-c.y)/frameH*1000)/10}};
const rect=(el)=>{if(!el)return null;const b=el.getBoundingClientRect();
return {x:Math.round((b.x-c.x)/c.width*1000)/10,y:Math.round((b.y-c.y)/frameH*1000)/10,w:Math.round(b.width/c.width*1000)/10,h:Math.round(b.height/frameH*1000)/10}};
const q=(sel)=>document.querySelector(sel);
const byText=(t)=>[...document.querySelectorAll('a,button')].find(x=>x.textContent.trim()===t);
const rowByText=(t)=>[...document.querySelectorAll('#audit-events li')].find(x=>x.textContent.includes(t));
const leaf=(t)=>[...document.querySelectorAll('#shell-canvas *')].find(e=>e.children.length===0&&e.textContent.trim()===t);
const leafLike=(t)=>[...document.querySelectorAll('#shell-canvas *')].find(e=>e.children.length===0&&e.textContent.includes(t));
const upTo=(el,n)=>{while(el&&n-->0)el=el.parentElement;return el};
const unionRect=(a,b)=>{if(!a)return b?rect(b):null;if(!b)return rect(a);const ar=a.getBoundingClientRect(),br=b.getBoundingClientRect();
const x1=Math.min(ar.x,br.x),y1=Math.min(ar.y,br.y),x2=Math.max(ar.x+ar.width,br.x+br.width),y2=Math.max(ar.y+ar.height,br.y+br.height);
return {x:Math.round((x1-c.x)/c.width*1000)/10,y:Math.round((y1-c.y)/frameH*1000)/10,w:Math.round((x2-x1)/c.width*1000)/10,h:Math.round((y2-y1)/frameH*1000)/10}};
return JSON.stringify({note:point(q('#approval-decision-form textarea[name="reason"]')),note_rect:rect(q('#approval-decision-form textarea[name="reason"]')),approve:point(q('#approval-decision-form button[value="approve"]')),view_run:point(byText('View run')),view_activity:point(byText('View activity')),command_rect:rect(q('#shell-canvas [id^="approval-command-"]')),action_rect:rect(leaf('Action')&&leaf('Action').parentElement),why_rect:rect(leaf('Why')&&leaf('Why').parentElement),output_rect:rect(leaf('Output')&&upTo(leaf('Output'),2)),auth_rect:unionRect(leafLike('Actor')&&upTo(leafLike('Actor'),2),leafLike('Target')&&upTo(leafLike('Target'),2)),audit_row:point(rowByText('Run succeeded')),audit_row_rect:rect(rowByText('Run succeeded')),payload_rect:rect(q('#audit-payload-json'))})})()`

func captureLoopTake(ctx context.Context, manager *Manager, config DocsConfig) (map[string]string, error) {
	// An isolated session (own profile) so signing in as Jordan never touches
	// the shared capture profile's demo@ session.
	session, err := manager.Session(ctx, config.BaseURL, true)
	if err != nil {
		return nil, err
	}
	defer session.Close()
	if err := session.Viewport(1280, 2800, 2, false); err != nil {
		return nil, err
	}
	if err := session.Navigate("/app/demo"); err != nil {
		return nil, err
	}
	if err := session.Login("jordan@emisar.dev"); err != nil {
		return nil, err
	}
	if err := session.Navigate("/app/demo/approvals"); err != nil {
		return nil, err
	}
	if err := clickByScript(session, clickRowLink(`#pending a[href*="/approvals/"]`, "caddy.reload_config"), "pending caddy.reload_config approval"); err != nil {
		return nil, fmt.Errorf("no pending caddy.reload_config request — reseed first: %w", err)
	}
	// Bounce until the LiveView is connected: the decide form on the dead
	// pre-connect render swallows input and clicks.
	if err := session.Ready(15*time.Second, `#approval-decision-form`); err != nil {
		return nil, err
	}

	colors := map[string]string{}
	frame := func(name string) error {
		s, ok := loopFrameByName(name)
		if !ok {
			return fmt.Errorf("unknown loop frame %q", name)
		}
		color, err := captureDocElement(session, config, s)
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		colors[name] = color
		fmt.Fprintf(manager.Out, "  %s w=%d bg=%s\n", name, s.width(), color)
		return nil
	}

	if err := frame("loop-approval-pending"); err != nil {
		return nil, err
	}
	printTargets(session, manager.Out, "approval")

	if err := chromedp.Run(session.Context,
		chromedp.SendKeys(`#approval-decision-form textarea[name="reason"]`, loopDecisionNote, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := frame("loop-approval-note"); err != nil {
		return nil, err
	}

	// Approve for real. The decide form disappears once the request is
	// decided, so its absence is the precise "the approve committed" signal.
	if err := chromedp.Run(session.Context,
		chromedp.Click(`#approval-decision-form button[value="approve"]`, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := waitGone(session, `#approval-decision-form`, 15*time.Second); err != nil {
		return nil, fmt.Errorf("approve did not commit: %w", err)
	}
	// Dismiss the "Done" flash so the approved frame is the record, not the
	// toast. The flash dismisses on click; retry until none is visible (the
	// flash is position:fixed, so test the rect — offsetParent is always null).
	if err := clickByScript(session, `(()=>{const vis=[...document.querySelectorAll('[data-flash]')].filter(e=>!e.hidden&&e.getBoundingClientRect().width>0);if(!vis.length)return true;vis.forEach(e=>e.click());return false})()`, "flash dismissal"); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, ""); err != nil {
		return nil, err
	}
	if err := frame("loop-approval-approved"); err != nil {
		return nil, err
	}

	// The approved run dispatches to the live runner immediately; follow it
	// and wait for the terminal success state before shooting.
	if err := clickByScript(session, clickText("View run"), "View run"); err != nil {
		return nil, err
	}
	if err := waitText(session, "success", 30*time.Second); err != nil {
		return nil, fmt.Errorf("approved run did not reach success — is the edge-fra-01 container (with the caddy stub) connected? %w", err)
	}
	if err := session.Ready(10*time.Second, ""); err != nil {
		return nil, err
	}
	if err := frame("loop-run-success"); err != nil {
		return nil, err
	}
	printTargets(session, manager.Out, "run")

	// Frame 5 is the REAL destination of the cursor's "View activity" click on
	// the run page: the audit log pre-filtered to this dispatch's request-id
	// trace — the filter state in the frame is exactly what the click produces.
	if err := clickByScript(session, clickText("View activity"), "View activity"); err != nil {
		return nil, err
	}
	if err := clickByScript(session, collapseAuditFilters, "audit filter collapse"); err != nil {
		return nil, err
	}
	if err := frame("loop-audit-trail"); err != nil {
		return nil, err
	}
	printTargets(session, manager.Out, "audit")

	// The loop's own succeeded row (the newest) opens the forensic close-up
	// through the row's real link.
	if err := clickByScript(session, clickRowLink(`#audit-events a[href*="/audit/"]`, "Run succeeded"), "Run succeeded audit row"); err != nil {
		return nil, err
	}
	if err := waitText(session, "Payload", 15*time.Second); err != nil {
		return nil, fmt.Errorf("audit event detail did not open: %w", err)
	}
	if err := session.Ready(10*time.Second, ""); err != nil {
		return nil, err
	}
	if err := frame("loop-audit-event"); err != nil {
		return nil, err
	}
	printTargets(session, manager.Out, "audit event")
	return colors, nil
}

func loopFrameByName(name string) (shot, bool) {
	for _, s := range loopFrames {
		if s.Name == name {
			return s, true
		}
	}
	return shot{}, false
}

func printTargets(session *Session, out io.Writer, page string) {
	var targets string
	if err := chromedp.Run(session.Context, chromedp.Evaluate(loopTargets, &targets)); err == nil {
		fmt.Fprintf(out, "  loop targets (%s page): %s\n", page, targets)
	}
}

// waitGone polls until no element matches the selector.
func waitGone(session *Session, selector string, timeout time.Duration) error {
	quoted, _ := json.Marshal(selector)
	script := `(()=>!document.querySelector(` + string(quoted) + `))()`
	deadline := time.Now().Add(timeout)
	for {
		var gone bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &gone)); err != nil {
			return err
		}
		if gone {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s still present after %s", selector, timeout)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// waitText polls until the workspace canvas contains the given text.
func waitText(session *Session, text string, timeout time.Duration) error {
	quoted, _ := json.Marshal(text)
	script := `(()=>{const el=document.querySelector('#shell-canvas');return !!el && el.textContent.includes(` + string(quoted) + `)})()`
	deadline := time.Now().Add(timeout)
	for {
		var found bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &found)); err != nil {
			return err
		}
		if found {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%q did not appear within %s", text, timeout)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func (s shot) width() int {
	if s.Width == 0 {
		return defaultWidth
	}
	return s.Width
}

// selectShots resolves the --only names; an unknown name is an error (a typo
// silently capturing nothing would read as success). Any loop-* frame name
// selects the WHOLE approval-loop take — its frames come from one continuous
// interaction, so a single frame can't regenerate alone.
func selectShots(only []string) ([]shot, bool, error) {
	if len(only) == 0 {
		all := append(append([]shot{}, docsShots...), keycloakShots...)
		return all, true, nil
	}
	byName := map[string]shot{}
	for _, s := range append(append([]shot{}, docsShots...), keycloakShots...) {
		byName[s.Name] = s
	}
	loopNames := map[string]bool{}
	for _, s := range loopFrames {
		loopNames[s.Name] = true
	}
	selected := make([]shot, 0, len(only))
	runLoop := false
	for _, name := range only {
		if loopNames[name] {
			runLoop = true
			continue
		}
		s, ok := byName[name]
		if !ok {
			return nil, false, fmt.Errorf("unknown docs shot %q (see docsShots/keycloakShots/loopFrames in tools/internal/browser/docs.go)", name)
		}
		selected = append(selected, s)
	}
	return selected, runLoop, nil
}

func splitShots(shots []shot) (portal, keycloak []shot) {
	for _, s := range shots {
		if s.Keycloak {
			keycloak = append(keycloak, s)
		} else {
			portal = append(portal, s)
		}
	}
	return portal, keycloak
}

var rgbPattern = regexp.MustCompile(`\d+`)

func rgbHex(value string) string {
	parts := rgbPattern.FindAllString(value, 3)
	if len(parts) != 3 {
		return "#09090b"
	}
	result := "#"
	for _, part := range parts {
		number, _ := strconv.Atoi(part)
		result += fmt.Sprintf("%02x", number)
	}
	return result
}

// highlightControls outlines each label's field group in emerald, the same
// treatment the vendor-console captures use, so one guide reads one way whichever
// console a step is in. A label that matches nothing FAILS the capture — a shot
// that silently loses its outline is a broken instruction, which is exactly how
// the Okta lifecycle screenshot shipped bare.
// highlightControls outlines the control each label names. Two prefixes change
// what gets outlined: "row:" takes the whole table row the text sits in — a list
// where the reader is being pointed at two entries among a dozen, not at a field
// — and "css:" names the control outright, for a widget whose label belongs to
// no single input (a repeating multi-value field).
func highlightControls(session *Session, labels []string) error {
	for _, label := range labels {
		wanted, row := strings.CutPrefix(label, "row:")
		wanted, direct := strings.CutPrefix(wanted, "css:")
		script := fmt.Sprintf(`(function(){
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const crop = document.querySelector('[data-shot="1"]');
  const edge = crop ? crop.getBoundingClientRect() : null;
  const inside = el => {
    if (!edge) return true;
    const box = el.getBoundingClientRect();
    return box.left >= edge.left - 1 && box.right <= edge.right + 1;
  };
  const paint = el => {
    // Outward by default, so the outline rings the control instead of cropping
    // its own last letter — a box drawn 3px inside a label sized to its text cuts
    // through the text. A full-width control has no room to either side, so that
    // one insets; the top and bottom are handled by the crop's spacers instead.
    const box = el.getBoundingClientRect();
    const tight = !edge || box.left - edge.left < 6 || edge.right - box.right < 6;
    el.style.outline = '3px solid #10b981';
    el.style.outlineOffset = tight ? '-3px' : '3px';
    el.style.borderRadius = '8px';
    return true;
  };
  if (%t) {
    const direct = document.querySelector(%q);
    return direct && visible(direct) ? paint(direct) : false;
  }
  const hits = [...document.querySelectorAll('label,legend,h2,h3,p,span,div,td,th,a')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  let node = hits[0];
  if (!node) return false;
  if (%t) {
    const tr = node.closest('tr');
    return tr ? paint(tr) : false;
  }
  // A <label for=...> names its control outright; take that rather than guessing
  // by climbing. The climb below can drift onto a NEIGHBOUR's input and outline
  // the wrong thing while still reporting success — which it did once. The text
  // is often a span INSIDE that label, so look up as well as at the node itself.
  const field = 'input,select,textarea,[role=radio],[role=checkbox]';
  const labelled = node.closest('label[for]') || (node.getAttribute('for') ? node : null);
  let control = labelled ? document.getElementById(labelled.getAttribute('for')) : null;
  if (!control) {
    // Climb to the field group, then outline the CONTROL inside it. Outlining the
    // group itself puts the line on the crop boundary, where the element
    // screenshot clips it away — which is how a "highlighted" shot came back with
    // one green edge showing.
    // Inputs before buttons, in two passes. A form group's help popover is a
    // <button> that usually sits closer to the label than the control does, so
    // one combined search outlined the "?" icon and called it a hit.
    for (let up = 0; up < 4 && node.parentElement; up++) {
      if (node.querySelector(field)) break;
      node = node.parentElement;
    }
    control = node.querySelector(field) || node.querySelector('button') || node;
  }
  // A tick box on its own reads as a stray green square; the reader is being
  // pointed at the option, which is the box together with its wording.
  if (control.matches && control.matches('input[type=checkbox],input[type=radio]') && control.parentElement) {
    control = control.parentElement;
  }
  // A switch paints a sibling and hides its real input, so an outline on the
  // input draws nothing at all. Walk out to the first ancestor with a box.
  while (control && !visible(control) && control.parentElement) control = control.parentElement;
  if (!control) return false;
  // A multi-value field (Keycloak's redirect URIs) has no label/for and its
  // group runs wider than the crop, so the outline's right edge fell outside the
  // picture. Narrow to the control inside it that the reader can actually see.
  if (!inside(control)) {
    const inner = [...control.querySelectorAll(field)].find(el => visible(el) && inside(el));
    if (inner) control = inner;
  }
  return paint(control);
})()`, direct, wanted, wanted, row)
		var marked bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &marked)); err != nil {
			return err
		}
		if !marked {
			return fmt.Errorf("nothing labelled %q to highlight", label)
		}
	}
	return nil
}

func captureDocElement(session *Session, config DocsConfig, s shot) (string, error) {
	const selector = `[data-shot="1"]`
	// Mark + settle, twice if needed: when a reveal click's LiveView navigation
	// lands AFTER the first mark, the marked node detaches (the layout re-renders)
	// and the settle loop can never see it again — re-marking finds the live node.
	settled := false
	for attempt := 0; attempt < 2 && !settled; attempt++ {
		if err := session.MarkAnchor(s.Anchor, "data-shot"); err != nil {
			return "", fmt.Errorf("%s: %w", s.Name, err)
		}
		// A long list (the member roster) makes the anchor far taller than the shot
		// needs — and past a point the element screenshot clips its top. Hide the rows
		// past Rows so the anchor shrinks to its header + the first Rows rows before
		// it settles and is shot; the tail simply doesn't render.
		if s.Rows > 0 && s.RowSelector != "" {
			hide := fmt.Sprintf(`(function(){const rows=document.querySelectorAll(%q);for(let i=%d;i<rows.length;i++)rows[i].style.display='none';return true})()`, s.RowSelector, s.Rows)
			if err := chromedp.Run(session.Context, chromedp.Evaluate(hide, nil)); err != nil {
				return "", err
			}
		}
		if err := highlightControls(session, s.Highlight); err != nil {
			return "", fmt.Errorf("%s: %w", s.Name, err)
		}
		// Breathing room under the outline. The crop is the anchor's CONTENT box, so
		// padding does not grow it — a highlighted control reaching the anchor's edge
		// has its outline on that boundary and the last row rounds away at 2x, which
		// is how the first highlighted shots came back with a shaved bottom edge. A
		// spacer child grows the content box, which the crop does follow.
		if len(s.Highlight) > 0 {
			spacer := `(function(){
  const el = document.querySelector('[data-shot="1"]');
  if (!el) return false;
  if (el.querySelector('[data-shot-spacer]')) return true;
  const pad = () => {
    const el = document.createElement('div');
    el.setAttribute('data-shot-spacer', '1');
    el.style.height = '12px';
    return el;
  };
  // Both ends. A control on the crop's TOP edge has the same problem as one on
  // its bottom, and there is no offset that rings a control on one edge without
  // cutting through its label on the other — outline-offset is one value for all
  // four sides.
  el.insertBefore(pad(), el.firstChild);
  el.appendChild(pad());
  return true;
})()`
			if err := chromedp.Run(session.Context, chromedp.Evaluate(spacer, nil)); err != nil {
				return "", fmt.Errorf("%s: %w", s.Name, err)
			}
		}
		switch err := session.Ready(10*time.Second, selector); {
		case err == nil:
			settled = true
		case attempt == 1:
			return "", err
		}
	}
	path := filepath.Join(config.Temp, s.Name+".png")
	if err := session.ElementScreenshot(selector, path, 2); err != nil {
		return "", err
	}
	var color string
	script := `(function(){let el=document.querySelector('[data-shot="1"]');while(el){const c=getComputedStyle(el).backgroundColor;if(c&&c!=='rgba(0, 0, 0, 0)'&&c!=='transparent')return c;el=el.parentElement;}return 'rgb(9, 9, 11)'})()`
	if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &color), chromedp.Evaluate(`document.querySelector('[data-shot="1"]')?.removeAttribute('data-shot')`, nil)); err != nil {
		return "", err
	}
	return rgbHex(color), nil
}

func imageCommand(tool string, args ...string) ([]byte, error) {
	if _, err := exec.LookPath("magick"); err == nil {
		if tool != "convert" {
			args = append([]string{tool}, args...)
		}
		return exec.Command("magick", args...).CombinedOutput()
	}
	return exec.Command(tool, args...).CombinedOutput()
}

// clickByScript retries while the target is missing: a prior click's LiveView
// navigation may still be in flight (Ready can't observe it), so the element
// this click wants often exists only a beat later.
func clickByScript(session *Session, script, label string) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		var clicked bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &clicked)); err != nil {
			return err
		}
		if clicked {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s was not found", label)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// captureShot sets the shot's viewport, navigates, runs its reveal clicks, and
// crops to its anchor. Returns the cropped element's background color.
func captureShot(session *Session, config DocsConfig, s shot) (string, error) {
	if err := session.Viewport(int64(s.width()), 2800, 2, false); err != nil {
		return "", err
	}
	if err := session.Navigate(s.Path); err != nil {
		return "", err
	}
	for _, click := range s.Clicks {
		if err := clickByScript(session, click, s.Name); err != nil {
			return "", err
		}
		if err := session.Ready(10*time.Second, ""); err != nil {
			return "", err
		}
	}
	return captureDocElement(session, config, s)
}

func captureKeycloakGuide(ctx context.Context, manager *Manager, config DocsConfig, shots []shot) (map[string]string, error) {
	if config.KeycloakURL == "" {
		return nil, fmt.Errorf("a Keycloak URL is required for the Keycloak documentation shots")
	}
	selected := make(map[string]shot, len(shots))
	for _, s := range shots {
		selected[s.Name] = s
	}
	session, err := manager.Session(ctx, config.KeycloakURL, true)
	if err != nil {
		return nil, err
	}
	defer session.Close()
	if err := session.Viewport(docsWidth, 1600, 2, false); err != nil {
		return nil, err
	}
	if err := session.Navigate("/admin/master/console/"); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.WaitVisible(`#username`, chromedp.ByQuery),
		chromedp.SendKeys(`#username`, "admin", chromedp.ByQuery),
		chromedp.SendKeys(`#password`, "admin", chromedp.ByQuery),
		chromedp.Click(`#kc-login`, chromedp.ByQuery)); err != nil {
		return nil, fmt.Errorf("signing in to the Keycloak dev admin console: %w", err)
	}
	if err := session.Ready(15*time.Second, `#nav-item-realms`); err != nil {
		return nil, err
	}
	if err := session.Navigate("/admin/master/console/#/master/realms"); err != nil {
		return nil, err
	}
	if err := clickByScript(session, `(()=>{const link=document.querySelector('a[href="#/emisar"]');if(!link)return false;link.click();return true})()`, "emisar realm"); err != nil {
		return nil, err
	}
	if err := waitSelectorText(session, `[data-testid="currentRealm"]`, "emisar", 10*time.Second); err != nil {
		return nil, err
	}
	if err := session.Navigate("/admin/master/console/#/emisar/clients"); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `[data-testid="createClient"]`); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.Click(`[data-testid="createClient"]`, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `#clientId`); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.SendKeys(`#clientId`, "emisar-portal", chromedp.ByQuery),
		chromedp.SendKeys(`#name`, "emisar", chromedp.ByQuery),
		chromedp.Evaluate(`document.activeElement?.blur()`, nil)); err != nil {
		return nil, err
	}

	colors := map[string]string{}
	capture := func(name string) error {
		s, ok := selected[name]
		if !ok {
			return nil
		}
		color, captureErr := captureDocElement(session, config, s)
		if captureErr != nil {
			return captureErr
		}
		colors[name] = color
		fmt.Fprintf(manager.Out, "  %s w=%d bg=%s\n", name, s.width(), color)
		return nil
	}
	if err := capture("keycloak-client-general"); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.Click(`#kc-main-content-page-container button[type="submit"]`, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `[data-testid="capability-config-form"]`); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.Click(`#kc-authentication`, chromedp.ByQuery),
		chromedp.Click(`#kc-pkce-required-switch`, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := waitChecked(session, `#kc-authentication`, 10*time.Second); err != nil {
		return nil, err
	}
	if err := waitChecked(session, `#kc-pkce-required-switch`, 10*time.Second); err != nil {
		return nil, err
	}
	if err := capture("keycloak-client-capabilities"); err != nil {
		return nil, err
	}
	if err := clickByScript(
		session,
		clickText("Next"),
		"Keycloak capability form Next button",
	); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `[data-testid="redirectUris0"]`); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.SendKeys(`[data-testid="redirectUris0"]`, "https://emisar.dev/sign_in/sso/callback", chromedp.ByQuery),
		chromedp.Evaluate(`document.activeElement?.blur()`, nil)); err != nil {
		return nil, err
	}
	if err := capture("keycloak-client-redirect"); err != nil {
		return nil, err
	}

	// Leave the wizard without saving. The existing seeded client carries the
	// same production-relevant shape and keeps the capture idempotent.
	if err := session.Navigate("/admin/master/console/#/emisar/clients"); err != nil {
		return nil, err
	}
	if err := clickByScript(session, `(()=>{const link=[...document.querySelectorAll('a')].find((candidate)=>(candidate.textContent||'').trim()==='emisar-portal');if(!link)return false;link.click();return true})()`, "seeded emisar-portal client"); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `[data-testid="clientSettingsTab"]`); err != nil {
		return nil, err
	}
	if err := clickByScript(session, clickText("Credentials"), "Credentials tab"); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `#kc-client-secret`); err != nil {
		return nil, err
	}
	var secretMasked bool
	if err := chromedp.Run(session.Context,
		chromedp.Evaluate(`document.querySelector('#kc-client-secret')?.type === 'password'`, &secretMasked)); err != nil {
		return nil, err
	}
	if !secretMasked {
		return nil, fmt.Errorf("the Keycloak client secret is not password-masked; refusing to capture")
	}
	if err := capture("keycloak-client-secret"); err != nil {
		return nil, err
	}
	if err := chromedp.Run(session.Context,
		chromedp.Click(`[data-testid="clientScopesTab"]`, chromedp.ByQuery)); err != nil {
		return nil, err
	}
	if err := session.Ready(10*time.Second, `table[aria-label="Client scopes"]`); err != nil {
		return nil, err
	}
	if err := verifyDefaultKeycloakScopes(session); err != nil {
		return nil, err
	}
	if err := capture("keycloak-client-scopes"); err != nil {
		return nil, err
	}
	return colors, nil
}

func waitSelectorText(session *Session, selector, text string, timeout time.Duration) error {
	selectorJSON, _ := json.Marshal(selector)
	textJSON, _ := json.Marshal(text)
	script := `(()=>document.querySelector(` + string(selectorJSON) + `)?.textContent.trim()===` + string(textJSON) + `)()`
	return waitScript(session, script, selector+" text "+text, timeout)
}

func waitChecked(session *Session, selector string, timeout time.Duration) error {
	selectorJSON, _ := json.Marshal(selector)
	script := `(()=>document.querySelector(` + string(selectorJSON) + `)?.checked===true)()`
	return waitScript(session, script, selector+" checked", timeout)
}

func waitScript(session *Session, script, label string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		var ready bool
		if err := chromedp.Run(session.Context, chromedp.Evaluate(script, &ready)); err != nil {
			return err
		}
		if ready {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s did not become ready within %s", label, timeout)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func verifyDefaultKeycloakScopes(session *Session) error {
	script := `(()=>['email','profile'].every((scope)=>[...document.querySelectorAll('table[aria-label="Client scopes"] tbody tr')].some((row)=>{const text=(row.textContent||'').replace(/\s+/g,' ').trim();return text.startsWith(scope+' ')&&text.includes(' Default')})))()`
	if err := waitScript(session, script, "email and profile default client scopes", 10*time.Second); err != nil {
		return fmt.Errorf("capture Keycloak client scopes: %w", err)
	}
	return nil
}

// processShot converts a captured PNG into the bordered, resized webp, keeping
// only the top TopCSS CSS pixels first when set.
func processShot(config DocsConfig, s shot, color string, out io.Writer) error {
	png := filepath.Join(config.Temp, s.Name+".png")
	destination := filepath.Join(config.Static, filepath.FromSlash(s.Output))
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	widthOutput, commandErr := imageCommand("identify", "-format", "%w", png)
	if commandErr != nil {
		return fmt.Errorf("identify %s: %w: %s", png, commandErr, widthOutput)
	}
	width := strings.TrimSpace(string(widthOutput))
	args := []string{png}
	if s.TopCSS != 0 {
		// Crop to the top TopCSS CSS pixels AND pad a shorter capture out to that
		// exact height, so every TopCSS shot in a set (the loop cast frames) has
		// identical dimensions regardless of each page's natural height. The crop
		// height derives from the captured width (not an assumed device scale):
		// the element renders at width()-CSS wide whatever the effective pixel
		// density, so width_px * TopCSS / width() is scale-independent.
		pixels, atoiErr := strconv.Atoi(width)
		if atoiErr != nil {
			return fmt.Errorf("identify %s: unexpected width %q", png, width)
		}
		box := fmt.Sprintf("%dx%d", pixels, pixels*s.TopCSS/s.width())
		args = append(args, "-crop", box+"+0+0", "+repage", "-background", color, "-extent", box)
	}
	args = append(args, "-resize", "1600x>")
	if !s.NoBorder {
		args = append(args, "-bordercolor", color, "-border", "40")
	}
	args = append(args, "-quality", "82", destination)
	if output, commandErr := imageCommand("convert", args...); commandErr != nil {
		return fmt.Errorf("convert %s: %w: %s", s.Name, commandErr, bytes.TrimSpace(output))
	}
	fmt.Fprintf(out, "  -> %s\n", s.Output)
	return nil
}

func CaptureDocs(ctx context.Context, manager *Manager, config DocsConfig) error {
	if config.Email == "" {
		config.Email = "demo@emisar.dev"
	}
	for _, dir := range []string{config.Temp, config.Static} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	shots, runLoop, err := selectShots(config.Only)
	if err != nil {
		return err
	}
	portalShots, selectedKeycloakShots := splitShots(shots)

	// Capture each shot independently: one bad anchor skips its shot, never the run.
	colors := map[string]string{}
	var failed []string
	if len(portalShots) > 0 {
		session, sessionErr := manager.Session(ctx, config.BaseURL, false)
		if sessionErr != nil {
			return sessionErr
		}
		defer session.Close()
		// Log in once at a default viewport; each shot sets its own width.
		if err := session.Viewport(defaultWidth, 2800, 2, false); err != nil {
			return err
		}
		if err := session.Navigate("/app/demo"); err != nil {
			return err
		}
		current, _ := session.CurrentURL()
		if !strings.Contains(current, "/app/") {
			if err := session.Login(config.Email); err != nil {
				return err
			}
		}
		for _, s := range portalShots {
			color, captureErr := captureShot(session, config, s)
			if captureErr != nil {
				failed = append(failed, fmt.Sprintf("%s (%v)", s.Name, captureErr))
				fmt.Fprintf(manager.Out, "  SKIP %s: %v\n", s.Name, captureErr)
				continue
			}
			colors[s.Name] = color
			fmt.Fprintf(manager.Out, "  %s w=%d bg=%s\n", s.Name, s.width(), color)
		}
	}
	if len(selectedKeycloakShots) > 0 {
		keycloakColors, captureErr := captureKeycloakGuide(ctx, manager, config, selectedKeycloakShots)
		if captureErr != nil {
			return captureErr
		}
		for name, color := range keycloakColors {
			colors[name] = color
		}
	}

	processing := shots
	if runLoop {
		loopColors, loopErr := captureLoopTake(ctx, manager, config)
		if loopErr != nil {
			failed = append(failed, fmt.Sprintf("approval-loop take (%v)", loopErr))
			fmt.Fprintf(manager.Out, "  SKIP approval-loop take: %v\n", loopErr)
		} else {
			for name, color := range loopColors {
				colors[name] = color
			}
			processing = append(append([]shot{}, shots...), loopFrames...)
		}
	}

	for _, s := range processing {
		color, ok := colors[s.Name]
		if !ok {
			continue
		}
		if err := processShot(config, s, color, manager.Out); err != nil {
			return err
		}
	}
	if len(failed) > 0 {
		fmt.Fprintf(manager.Out, "  %d shot(s) skipped: %s\n", len(failed), strings.Join(failed, "; "))
	}
	return nil
}
