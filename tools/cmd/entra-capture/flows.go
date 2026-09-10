package main

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"

	"github.com/andrewdryga/emisar/tools/internal/capture"
)

// The Entra screens the SSO and SCIM guides show beyond the registration form:
// the saved app's overview and client secrets, creating the enterprise
// application and assigning the people to sync, and the provisioning blade with
// its connection form, attribute mappings, and saved connectivity. Each flow
// walks the portal the way an operator does — list, open, pick — because a
// route built by hand lands on "Dashboard not found" where the portal's own
// navigation routes.

// outlineStyle is how a step's control is ringed. The app blades clip a CSS
// outline, so they get a fixed-position ring instead; toolbars render their
// label beside a glyph, so a containment match stands in for an exact one.
type outlineStyle struct {
	exact     bool
	closest   string
	fixedRing bool
	scroll    bool
}

// outline rings the control a step names, searching every frame. A row's
// outline paints under its cells' backgrounds, so a table row is ringed cell by
// cell instead. FAIL on a miss, never warn: a screenshot with no outline is a
// broken instruction, and that is exactly how bare shots reached the docs.
func outline(ctx context.Context, frames *frameContexts, label string, style outlineStyle) error {
	script := fmt.Sprintf(`(() => {
  const text = %q, exact = %t, closest = %q, fixedRing = %t, scroll = %t;
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  for (const prior of document.querySelectorAll('[data-emisar-docs-highlight=true]')) prior.remove();
  const matches = el => {
    const own = (el.textContent || '').trim();
    return exact ? own === text : own.includes(text) && own.length < text.length + 8;
  };
  const hits = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && matches(el))
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  if (!hits.length) return false;
  const t = hits[0].closest(closest) || (fixedRing ? hits[0].parentElement : null) || hits[0];
  if (scroll) t.scrollIntoView({block: 'center'});
  if (t.tagName === 'TR') {
    const cells = [...t.children];
    cells.forEach((cell, i) => {
      const ring = ['inset 0 3px 0 #10b981', 'inset 0 -3px 0 #10b981'];
      if (i === 0) ring.push('inset 3px 0 0 #10b981');
      if (i === cells.length - 1) ring.push('inset -3px 0 0 #10b981');
      cell.style.boxShadow = ring.join(', ');
    });
  } else if (fixedRing) {
    const box = t.getBoundingClientRect();
    const ring = document.createElement('div');
    ring.dataset.emisarDocsHighlight = 'true';
    Object.assign(ring.style, {
      position: 'fixed', left: (box.left - 3) + 'px', top: (box.top - 3) + 'px',
      width: (box.width + 6) + 'px', height: (box.height + 6) + 'px',
      border: '3px solid #10b981', borderRadius: '6px', boxSizing: 'border-box',
      pointerEvents: 'none', zIndex: '2147483647'
    });
    document.body.appendChild(ring);
  } else {
    t.style.outline = '3px solid #10b981';
    t.style.outlineOffset = '3px';
    t.style.borderRadius = '6px';
  }
  return true;
})()`, label, style.exact, style.closest, style.fixedRing, style.scroll)
	marked, err := frames.firstFrame(ctx, script)
	if err != nil {
		return err
	}
	if !marked {
		frames.describeFrames(ctx)
		return fmt.Errorf("nothing labelled %q to outline; visible controls: %q", label, frames.visibleControls(ctx))
	}
	fmt.Printf("  outlined %q\n", label)
	return chromedp.Run(ctx, chromedp.Sleep(600*time.Millisecond))
}

var (
	// The app blades: the ring lands on the control or row carrying the label.
	controlOutline = outlineStyle{exact: true, closest: "button,a,[role=button],[role=menuitem],li,tr", fixedRing: true, scroll: true}
	// Enterprise-application screens: the surrounding block, ringed in place.
	blockOutline = outlineStyle{exact: true, closest: "div,section,li,tr,button,a", scroll: true}
	// Provisioning status text: its own section, left where the blade put it.
	sectionOutline = outlineStyle{exact: true, closest: "div,section"}
)

// maskTenant scrubs tenant identifiers out of every frame before a shot — the
// object and application GUIDs, and (on the provisioning screens) the SCIM
// host, which names a real deployment.
func maskTenant(ctx context.Context, frames *frameContexts, scimHost bool) error {
	scim := ""
	if scimHost {
		scim = `.replace(/scim\.[a-z0-9.-]+/gi, 'scim.••••••••••••••••••••')`
	}
	script := `(() => {
  const scrub = value => value
    .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '••••••••••••••••••••')` + scim + `;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    node.nodeValue = scrub(node.nodeValue || '');
  }
  for (const input of document.querySelectorAll('input')) {
    if (input.value) input.value = scrub(input.value);
  }
  return true;
})()`
	return frames.everyFrame(ctx, script)
}

func maskedShot(ctx context.Context, frames *frameContexts, outDir, name string, width float64, scimHost bool) error {
	if err := maskTenant(ctx, frames, scimHost); err != nil {
		return err
	}
	return shot(ctx, outDir, name, belowTitleBar(width))
}

// clickInFrames dispatches a synthetic click on the smallest visible control
// carrying the label, in whichever frame holds it. Menu items inside a blade
// take a synthetic click; the widgets that need a real pointer event are
// clicked through clickTextAtCentre in the top document instead.
func clickInFrames(ctx context.Context, frames *frameContexts, label string) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const hits = [...document.querySelectorAll('button,a,[role=button],[role=menuitem],div')]
    .filter(el => visible(el) && (el.textContent || '').trim() === %q)
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length);
  if (!hits.length) return false;
  hits[0].click();
  return true;
})()`, label)
	return frames.firstFrame(ctx, script)
}

// clickIfPresent is a best-effort real click on a top-document label. It waits
// up to half a minute for the label to render — a blade's menu arrives well
// after its shell — because the portal's left menu sometimes needs a "Manage"
// expansion first and sometimes does not, so a miss is not a failure.
func clickIfPresent(ctx context.Context, label string, settle time.Duration) error {
	deadline := time.Now().Add(30 * time.Second)
	for {
		err := clickTextAtCentre(ctx, label)
		if err == nil {
			fmt.Printf("  clicked %q\n", label)
			return chromedp.Run(ctx, chromedp.Sleep(settle))
		}
		if time.Now().After(deadline) {
			fmt.Printf("  no %q to click\n", label)
			return nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(time.Second)); err != nil {
			return err
		}
	}
}

func sleep(ctx context.Context, d time.Duration) error {
	return chromedp.Run(ctx, chromedp.Sleep(d))
}

// appFlow captures the saved app's Overview (client id) and Certificates &
// secrets blades — the screens the SSO guide reads the credentials from.
func appFlow(ctx context.Context, frames *frameContexts, env map[string]string, outDir string) error {
	appID := env["ENTRA_CLIENT_ID"]
	if appID == "" {
		return errors.New("ENTRA_CLIENT_ID is empty — register the app first")
	}
	if err := chromedp.Run(ctx, chromedp.EmulateViewport(1440, 1000)); err != nil {
		return err
	}
	blade := "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/"
	if err := chromedp.Run(ctx, chromedp.Navigate(blade+"Overview/appId/"+appID), chromedp.Sleep(20*time.Second)); err != nil {
		return err
	}
	if err := capture.RequireText(ctx, "Application (client) ID", 90*time.Second); err != nil {
		_ = shot(ctx, outDir, "pw-01-app-overview-failed", nil)
		return fmt.Errorf("app overview never rendered: %w", err)
	}
	dismissOverlays(ctx)
	if err := outline(ctx, frames, "Application (client) ID", controlOutline); err != nil {
		return err
	}
	if err := maskedShot(ctx, frames, outDir, "pw-01-app-overview", 1440, false); err != nil {
		return err
	}

	if err := chromedp.Run(ctx, chromedp.Navigate(blade+"Credentials/appId/"+appID), chromedp.Sleep(20*time.Second)); err != nil {
		return err
	}
	dismissOverlays(ctx)
	if err := outline(ctx, frames, "New client secret", controlOutline); err != nil {
		return err
	}
	return maskedShot(ctx, frames, outDir, "pw-02-client-secrets", 1440, false)
}

// enterpriseAppFlow captures creating the enterprise application and assigning
// the people to sync. Both live in the Enterprise applications area rather than
// App registrations, and neither needs a provisioning configuration.
func enterpriseAppFlow(ctx context.Context, frames *frameContexts, env map[string]string, outDir string, galleryOnly bool) error {
	// The SCIM enterprise application, by the display name the tenant shows —
	// tenant state, like the ids, so it comes from the credentials file rather
	// than a name baked in here that the tenant has since moved away from.
	appName := env["ENTRA_SCIM_APP_NAME"]
	if appName == "" && !galleryOnly {
		return errors.New("ENTRA_SCIM_APP_NAME is required to open the enterprise application (see -flow inventory)")
	}
	if err := chromedp.Run(ctx, chromedp.EmulateViewport(1520, 950)); err != nil {
		return err
	}
	// 1. Creating the enterprise application. "Create your own application" is
	// the path for a SCIM app: the gallery entries are for products Microsoft
	// already knows, and emisar is not one of them.
	if err := chromedp.Run(ctx,
		chromedp.Navigate("https://portal.azure.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview"),
		chromedp.Sleep(20*time.Second),
	); err != nil {
		return err
	}
	if err := capture.RequireText(ctx, "New application", 90*time.Second); err != nil {
		return err
	}
	if err := clickTextAtCentre(ctx, "New application"); err != nil {
		return err
	}
	if err := sleep(ctx, 12*time.Second); err != nil {
		return err
	}
	if err := capture.RequireText(ctx, "Create your own application", 90*time.Second); err != nil {
		return err
	}
	if err := outline(ctx, frames, "Create your own application", blockOutline); err != nil {
		return err
	}
	if err := shot(ctx, outDir, "pw-10-create-enterprise-app", belowTitleBar(1520)); err != nil {
		return err
	}
	if galleryOnly {
		return nil
	}

	// 2. Assigning the people to sync. Users and groups on the app decides who
	// is in scope; provisioning only ever pushes what is assigned here. A FRESH
	// tab in the same signed-in session: hash-navigating away from the gallery
	// left the SPA wedged — the application list sat on its spinner past three
	// minutes — and closing the blade with Escape did not clear it.
	tab, cancel := chromedp.NewContext(ctx)
	defer cancel()
	tabFrames := trackFrames(tab)
	// A tab opened behind the first one is a hidden document, and the portal
	// defers a hidden blade's work: its menu rendered but its list sat on a
	// spinner for three minutes. Bring the tab forward before navigating.
	if err := chromedp.Run(tab,
		chromedp.EmulateViewport(1520, 950),
		page.BringToFront(),
		chromedp.Navigate("https://portal.azure.com/#blade/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/AllApps"),
		chromedp.Sleep(20*time.Second),
	); err != nil {
		return err
	}
	dismissOverlays(tab)

	// The direct route lands on the shell with nothing selected — the list only
	// loads once "All applications" under Manage is actually chosen.
	if err := clickIfPresent(tab, "Manage", 6*time.Second); err != nil {
		return fmt.Errorf("manage: %w", err)
	}
	if err := clickIfPresent(tab, "All applications", 20*time.Second); err != nil {
		return fmt.Errorf("all applications: %w", err)
	}
	// WAIT for the row, do not sample after a fixed pause. The application list
	// was still showing its spinner at 30 seconds, and a count taken then
	// reports the app as absent when it is merely late.
	if err := capture.RequireText(tab, appName, 180*time.Second); err != nil {
		_ = shot(tab, outDir, "pw-11-app-not-listed", nil)
		tabFrames.describeFrames(tab)
		return fmt.Errorf("the %q enterprise application never appeared in the list", appName)
	}
	if err := clickTextAtCentre(tab, appName); err != nil {
		return err
	}
	if err := sleep(tab, 20*time.Second); err != nil {
		return err
	}

	// The blade's menu item is present but HIDDEN — the app menu renders
	// collapsed, so a wait on visibility never resolves. Click the node itself.
	var opened bool
	if err := chromedp.Run(tab, chromedp.Evaluate(`(() => {
  const item = [...document.querySelectorAll('.fxc-menu-listView-item, [data-telemetryname]')]
    .find(el => (el.textContent || '').trim() === 'Users and groups');
  if (!item) return false;
  item.click();
  return true;
})()`, &opened)); err != nil {
		return err
	}
	if !opened {
		return errors.New("the app blade has no Users and groups item")
	}
	if err := sleep(tab, 8*time.Second); err != nil {
		return err
	}
	// Twice, and both are needed. The first click lands on a collapsed menu and
	// only expands it — the blade stayed on Overview. With the item now visible,
	// a real click routes.
	if err := capture.RequireText(tab, "Users and groups", 90*time.Second); err != nil {
		return err
	}
	if err := clickTextAtCentre(tab, "Users and groups"); err != nil {
		return err
	}
	if err := sleep(tab, 25*time.Second); err != nil {
		return err
	}
	// `+ Add user/group` renders beside a glyph, so containment stands in for
	// an exact match here.
	if err := outline(tab, tabFrames, "Add user/group", outlineStyle{closest: "div,section,li,tr,button,a", scroll: true}); err != nil {
		_ = shot(tab, outDir, "pw-11-assign-users-failed", nil)
		return err
	}
	return shot(tab, outDir, "pw-11-assign-users", nil)
}

// provisioningOptions picks which provisioning screens a run captures.
type provisioningOptions struct {
	mappings, connectivity, provisioningOnly bool
}

// provisioningFlow captures the enterprise application's Overview and its
// Provisioning blade, then one of: the connection form an operator fills, the
// attribute mapping with externalId opened, or the saved Connectivity
// credentials. The working routes are `#view/<Ext>/<Blade>/~/<Menu>/<params>`
// — learned by reading the URLs the portal itself produced.
func provisioningFlow(ctx context.Context, frames *frameContexts, env map[string]string, outDir string, opts provisioningOptions) error {
	principal, appID := env["ENTRA_SCIM_SERVICE_PRINCIPAL_ID"], env["ENTRA_SCIM_APP_ID"]
	if principal == "" || appID == "" {
		return errors.New("ENTRA_SCIM_SERVICE_PRINCIPAL_ID and ENTRA_SCIM_APP_ID are required")
	}
	if err := chromedp.Run(ctx,
		chromedp.EmulateViewport(1440, 1000),
		chromedp.Navigate("https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Provisioning/objectId/"+principal+"/appId/"+appID),
		chromedp.Sleep(28*time.Second),
	); err != nil {
		return err
	}
	dismissOverlays(ctx)
	if err := maskedShot(ctx, frames, outDir, "pw-11-enterprise-overview", 1440, true); err != nil {
		return err
	}

	// The blade renders; the deep link normalises to Overview, so reach
	// Provisioning through the left menu the way an operator does.
	for _, label := range []string{"Manage", "Provisioning"} {
		if err := clickIfPresent(ctx, label, 9*time.Second); err != nil {
			return err
		}
	}
	if err := sleep(ctx, 14*time.Second); err != nil {
		return err
	}
	// Best effort: a tenant that has never synced has no cycle status to ring.
	if err := outline(ctx, frames, "Current cycle status: Incremental sync completed", sectionOutline); err != nil {
		fmt.Println("  WARN", err)
	}
	if err := maskedShot(ctx, frames, outDir, "pw-12-provisioning", 1440, true); err != nil {
		return err
	}

	switch {
	case opts.mappings:
		return mappingsScreens(ctx, frames, outDir)
	case opts.connectivity:
		return connectivityScreen(ctx, frames, outDir)
	case opts.provisioningOnly:
		return nil
	}
	return connectionForm(ctx, frames, outDir)
}

// markMappingRow rings the externalId row of the attribute mapping table, or
// opens it when click is set.
func markMappingRow(ctx context.Context, frames *frameContexts, click bool) (bool, error) {
	script := fmt.Sprintf(`(() => {
  const click = %t;
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const externalID = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === 'externalId')
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  const row = externalID && externalID.closest('tr,[role=row]');
  if (!row) return false;
  row.scrollIntoView({block: 'center'});
  if (click) {
    const action = row.querySelector('button,a,[role=button]') || row;
    action.click();
    return true;
  }
  const cells = [...row.children];
  cells.forEach((cell, index) => {
    const ring = ['inset 0 3px 0 #10b981', 'inset 0 -3px 0 #10b981'];
    if (index === 0) ring.push('inset 3px 0 0 #10b981');
    if (index === cells.length - 1) ring.push('inset -3px 0 0 #10b981');
    cell.style.boxShadow = ring.join(', ');
  });
  return true;
})()`, click)
	return frames.firstFrame(ctx, script)
}

func mappingsScreens(ctx context.Context, frames *frameContexts, outDir string) error {
	for _, label := range []string{"Manage", "Attribute mapping"} {
		clicked, err := clickInFrames(ctx, frames, label)
		if err != nil {
			return err
		}
		if clicked {
			if err := sleep(ctx, 9*time.Second); err != nil {
				return err
			}
		}
	}
	marked, err := markMappingRow(ctx, frames, false)
	if err != nil {
		return err
	}
	if !marked {
		return errors.New("externalId mapping row was not found")
	}
	if err := maskedShot(ctx, frames, outDir, "pw-17-attribute-mapping", 1440, true); err != nil {
		return err
	}
	opened, err := markMappingRow(ctx, frames, true)
	if err != nil {
		return err
	}
	if !opened {
		return errors.New("externalId mapping row could not be opened")
	}
	if err := sleep(ctx, 12*time.Second); err != nil {
		return err
	}
	// The mapping editor's source/target row sits at a fixed spot in this
	// viewport; ring it in the top document over the blade.
	if err := chromedp.Run(ctx, chromedp.Evaluate(`(() => {
  const ring = document.createElement('div');
  Object.assign(ring.style, {
    position: 'fixed', left: '38px', top: '314px', width: '765px', height: '55px',
    border: '3px solid #10b981', borderRadius: '6px', boxSizing: 'border-box',
    pointerEvents: 'none', zIndex: '2147483647'
  });
  document.body.appendChild(ring);
  return true;
})()`, nil)); err != nil {
		return err
	}
	return maskedShot(ctx, frames, outDir, "pw-18-externalid-objectid", 1440, true)
}

func connectivityScreen(ctx context.Context, frames *frameContexts, outDir string) error {
	for _, label := range []string{"Manage", "Connectivity"} {
		clicked, err := clickInFrames(ctx, frames, label)
		if err != nil {
			return err
		}
		if clicked {
			if err := sleep(ctx, 8*time.Second); err != nil {
				return err
			}
		}
	}
	// The saved secret token is masked and the saved tenant URL replaced with
	// the documented one, in every frame, before anything is captured.
	if err := frames.everyFrame(ctx, `(() => {
  for (const input of document.querySelectorAll('input')) {
    if ((input.type || '').toLowerCase() === 'password') input.value = '••••••••••••••••••••';
    if (/^https?:\/\//i.test(input.value || '')) input.value = 'https://emisar.dev/scim/v2';
  }
  return true;
})()`); err != nil {
		return err
	}
	marked, err := frames.firstFrame(ctx, `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const anchor = [...document.querySelectorAll('*')]
    .filter(el => visible(el) && (el.textContent || '').trim() === 'Select authentication method:')
    .sort((a, b) => a.getElementsByTagName('*').length - b.getElementsByTagName('*').length)[0];
  let target = anchor;
  for (let up = 0; up < 10 && target; up++, target = target.parentElement) {
    const box = target.getBoundingClientRect();
    if (box.width >= 600 && box.height >= 220 && box.height <= 650) {
      target.style.outline = '3px solid #10b981';
      target.style.outlineOffset = '3px';
      target.style.borderRadius = '6px';
      return true;
    }
  }
  return false;
})()`)
	if err != nil {
		return err
	}
	if !marked {
		fmt.Println("  WARN the credential panel was not outlined")
	}
	return maskedShot(ctx, frames, outDir, "pw-16-credentials-filled", 1440, true)
}

var (
	provisioningText = regexp.MustCompile(`(?i)provisioning|Connect your application|Tenant URL`)
	tenantURLText    = regexp.MustCompile(`(?i)Tenant URL`)
)

// connectionForm opens "Connect your application" and fills the tenant URL an
// operator types, leaving the secret masked and nothing saved.
func connectionForm(ctx context.Context, frames *frameContexts, outDir string) error {
	texts, err := frames.frameTexts(ctx)
	if err != nil {
		return err
	}
	fmt.Println("  frames:", len(texts))
	var target *frameText
	for i := range texts {
		if provisioningText.MatchString(texts[i].Text) {
			target = &texts[i]
			fmt.Println("  MATCH frame:", truncate(texts[i].URL, 110))
		}
	}
	if target == nil {
		return nil
	}
	var connected bool
	if err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		return target.frame.evaluate(ctx, `(() => {
  const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0;
  const button = [...document.querySelectorAll('button, [role=button], a')]
    .find(el => visible(el) && /Connect your application/i.test(el.textContent || ''));
  if (!button) return false;
  button.click();
  return true;
})()`, &connected)
	})); err != nil {
		return err
	}
	fmt.Println("  connect button clicked:", connected)
	if err := sleep(ctx, 20*time.Second); err != nil {
		return err
	}
	if err := maskedShot(ctx, frames, outDir, "pw-13-connect", 1440, true); err != nil {
		return err
	}
	if err := sleep(ctx, 4*time.Second); err != nil {
		return err
	}

	// Find the frame that actually holds the form, then fill its own inputs —
	// never page-level, which matches the portal's top-bar search first.
	texts, err = frames.frameTexts(ctx)
	if err != nil {
		return err
	}
	var form *frameText
	for i := range texts {
		if tenantURLText.MatchString(texts[i].Text) {
			form = &texts[i]
			fmt.Println("  form frame:", truncate(texts[i].URL, 90))
		}
	}
	if form == nil {
		return nil
	}
	// Tenant URL is the first non-password field on this form: focus it in its
	// frame and type through real key events, which the React form accepts.
	var focused bool
	if err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		return form.frame.evaluate(ctx, `(() => {
  const inputs = [...document.querySelectorAll('input')];
  console.log('inputs in form frame:', inputs.length);
  const field = inputs.find(input => (input.getAttribute('type') || '') !== 'password');
  if (!field) return false;
  field.scrollIntoView({block: 'center'});
  field.focus();
  field.select();
  return true;
})()`, &focused)
	})); err != nil {
		return err
	}
	if focused {
		if err := chromedp.Run(ctx, chromedp.KeyEvent("https://emisar.dev/scim/v2"), chromedp.Sleep(time.Second)); err != nil {
			return err
		}
	}
	if err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		return form.frame.evaluate(ctx, `(() => {
  for (const input of document.querySelectorAll('input')) {
    if ((input.getAttribute('type') || '') === 'password') input.value = '••••••••••••••••••••';
  }
  return true;
})()`, nil)
	})); err != nil {
		return err
	}
	if err := sleep(ctx, 2500*time.Millisecond); err != nil {
		return err
	}
	if err := maskedShot(ctx, frames, outDir, "pw-16-credentials-filled", 1440, true); err != nil {
		return err
	}
	fmt.Println("  filled")
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
