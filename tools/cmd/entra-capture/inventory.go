package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// What this rig has left in the Entra tenant, and optionally removing it.
//
// The registration flow creates app registrations named "emisar" — seven
// duplicates accumulated before the list blade's failure to render made them
// visible — and for a long time nothing here could say so; see
// .agent/kb/rules/shared-capture-rigs-own-what-they-create.md. Every app
// registration and enterprise application is printed with a verdict beside it.
// A filter that can silently under-match must show what it looked at; "nothing
// to clean up" from a filter that matched nothing is not evidence of a clean
// tenant.
//
// Graph, not the portal's DOM: the portal renders blades in iframes and its
// list is virtualised; Graph answers the same question directly. The token is
// taken by watching the console authenticate its OWN calls rather than posting
// to an internal token endpoint whose contract we'd be guessing at — that
// guess returned nothing, and a token fetch that quietly yields '' is one edit
// away from reporting an empty tenant as a clean one.

const graphBase = "https://graph.microsoft.com/v1.0"

var bearer = regexp.MustCompile(`(?i)^bearer `)

// graph is one signed-in session's view of Microsoft Graph.
type graph struct {
	token  string
	client *http.Client
}

// openGraph loads the Enterprise applications blade — the one that lists what
// this rig creates, so loading it is what makes the console go and read that
// list — and keeps the bearer it used for Graph. The Entra admin center calls
// Graph from the browser; the Azure portal proxies the same reads through its
// own API, so its session never shows a Graph token.
func openGraph(ctx context.Context) (*graph, error) {
	var mu sync.Mutex
	token := ""
	chromedp.ListenTarget(ctx, func(ev any) {
		request, ok := ev.(*network.EventRequestWillBeSent)
		if !ok || !strings.Contains(request.Request.URL, "graph.microsoft.com") {
			return
		}
		for name, value := range request.Request.Headers {
			text, _ := value.(string)
			if strings.EqualFold(name, "authorization") && bearer.MatchString(text) {
				mu.Lock()
				token = text
				mu.Unlock()
			}
		}
	})
	if err := chromedp.Run(ctx,
		network.Enable(),
		chromedp.Navigate("https://entra.microsoft.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview"),
	); err != nil {
		return nil, err
	}
	for i := 0; i < 30; i++ {
		mu.Lock()
		found := token
		mu.Unlock()
		if found != "" {
			return &graph{token: found, client: &http.Client{Timeout: 60 * time.Second}}, nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
			return nil, err
		}
	}
	return nil, errors.New("could not obtain a Graph token from the console session — cannot list the tenant\nWITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN")
}

type graphRow struct {
	ID          string `json:"id"`
	AppID       string `json:"appId"`
	DisplayName string `json:"displayName"`
}

// list follows @odata.nextLink to the last page. A page cap under-lists
// exactly as silently as a bad filter: 200 rows fit today's tenant, and the day
// they don't, a truncated listing reads as a clean one.
func (g *graph) list(ctx context.Context, path string) ([]graphRow, error) {
	var rows []graphRow
	next := graphBase + path
	for next != "" {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, next, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Authorization", g.token)
		request.Header.Set("Accept", "application/json")
		response, err := g.client.Do(request)
		if err != nil {
			return nil, err
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			return nil, err
		}
		if response.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("graph refused the listing: %d", response.StatusCode)
		}
		var listing struct {
			Value    []graphRow `json:"value"`
			NextLink string     `json:"@odata.nextLink"`
		}
		if err := json.Unmarshal(body, &listing); err != nil {
			return nil, err
		}
		rows = append(rows, listing.Value...)
		next = listing.NextLink
	}
	return rows, nil
}

func (g *graph) delete(ctx context.Context, path string) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, graphBase+path, nil)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", g.token)
	response, err := g.client.Do(request)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	return response.StatusCode, nil
}

// servicePrincipalNamed finds the enterprise application with exactly this
// display name, reporting whether one exists.
func (g *graph) servicePrincipalNamed(ctx context.Context, name string) (graphRow, bool, error) {
	filter := url.QueryEscape("displayName eq '" + strings.ReplaceAll(name, "'", "''") + "'")
	rows, err := g.list(ctx, "/servicePrincipals?$select=id,appId,displayName&$filter="+strings.ReplaceAll(filter, "+", "%20"))
	if err != nil {
		return graphRow{}, false, err
	}
	for _, row := range rows {
		if row.DisplayName == name {
			return row, true, nil
		}
	}
	return graphRow{}, false, nil
}

// resolveSCIMApp fills ENTRA_SCIM_SERVICE_PRINCIPAL_ID and ENTRA_SCIM_APP_ID
// from the enterprise application's display name when the credentials file
// does not carry them, and says what it found so the ids can be pinned.
func resolveSCIMApp(ctx context.Context, g *graph, env map[string]string) error {
	if env["ENTRA_SCIM_SERVICE_PRINCIPAL_ID"] != "" && env["ENTRA_SCIM_APP_ID"] != "" {
		return nil
	}
	name := scimAppName(env)
	row, found, err := g.servicePrincipalNamed(ctx, name)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("no enterprise application named %q — set ENTRA_SCIM_APP_NAME to the one the tenant shows", name)
	}
	env["ENTRA_SCIM_SERVICE_PRINCIPAL_ID"] = row.ID
	env["ENTRA_SCIM_APP_ID"] = row.AppID
	fmt.Printf("  %q is service principal %s, app %s (set ENTRA_SCIM_SERVICE_PRINCIPAL_ID and ENTRA_SCIM_APP_ID to skip this lookup)\n", name, row.ID, row.AppID)
	return nil
}

type graphCollection struct {
	label, resource, selection string
	mine                       []graphRow
}

// auditTenant lists every app registration and enterprise application with a
// verdict, and removes the ones that are ours when remove is set.
//
// Ours is exactly the name this rig gives what it creates — "emisar", the
// registration form's display name — never a substring. The tenant also holds
// the "emisar login certification" and "emisar directory sync certification"
// objects the provider certification runs sign in and provision against; a
// `/emisar/` match claimed both, the accident okta-capture's filter had first.
// A keeper is identified by something it carries, never by a name the filter
// happens to miss: the saved walkthrough app registration whose appId is
// ENTRA_CLIENT_ID, and the SCIM enterprise application whose appId is
// ENTRA_SCIM_APP_ID (resolved through Graph when the file does not pin it).
// The registration, app, and provisioning flows resume those by id instead of
// creating yet another duplicate, so deleting either breaks the next run.
func auditTenant(ctx context.Context, env map[string]string, remove bool) error {
	if err := chromedp.Run(ctx, chromedp.EmulateViewport(1520, 950)); err != nil {
		return err
	}
	g, err := openGraph(ctx)
	if err != nil {
		return err
	}
	if err := resolveSCIMApp(ctx, g, env); err != nil {
		fmt.Println("  WARN", err)
	}
	keeper := func(row graphRow) bool {
		for _, key := range []string{"ENTRA_CLIENT_ID", "ENTRA_SCIM_APP_ID"} {
			if env[key] != "" && row.AppID == env[key] {
				return true
			}
		}
		return false
	}
	ours := func(row graphRow) bool { return strings.EqualFold(row.DisplayName, "emisar") && !keeper(row) }
	verdict := func(row graphRow) string {
		switch {
		case keeper(row):
			return "keep   "
		case ours(row):
			return "DELETE "
		}
		return "spare  "
	}

	// Both halves of what the rig creates. Deleting an application also takes
	// its service principal with it, so the cleanup below removes service
	// principals FIRST — a delete against a row that just vanished reads as a
	// failure it isn't.
	collections := []graphCollection{
		{label: "app registrations", resource: "applications", selection: "id,appId,displayName"},
		{label: "enterprise applications", resource: "servicePrincipals", selection: "id,appId,displayName,servicePrincipalType"},
	}
	for i := range collections {
		section := &collections[i]
		rows, err := g.list(ctx, "/"+section.resource+"?$select="+section.selection+"&$top=200")
		if err != nil {
			return fmt.Errorf("%s: %w\nWITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN", section.label, err)
		}
		// Object id first, then app id: the provisioning flow needs both for
		// the SCIM enterprise application, and this listing is where to read them.
		fmt.Printf("--- every %s, and what this run will do with it ---\n", strings.TrimSuffix(section.label, "s"))
		for _, row := range rows {
			fmt.Printf("  %s %-44s %s  app %s\n", verdict(row), row.DisplayName, row.ID, row.AppID)
		}
		fmt.Println("--- anything spared that this rig created is a filter gap, not a clean tenant ---")
		for _, row := range rows {
			if ours(row) {
				section.mine = append(section.mine, row)
			}
		}
		fmt.Printf("%d %s, %d of them ours\n", len(rows), section.label, len(section.mine))
	}

	if !remove {
		return nil
	}
	failed := 0
	for i := len(collections) - 1; i >= 0; i-- {
		section := collections[i]
		for _, row := range section.mine {
			status, err := g.delete(ctx, "/"+section.resource+"/"+row.ID)
			if err != nil {
				return err
			}
			if status != http.StatusNoContent {
				failed++
			}
			fmt.Printf("  removed %s (%s): %d\n", row.DisplayName, section.resource, status)
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d delete(s) did not return 204 — THIS TENANT CANNOT BE CALLED CLEAN", failed)
	}
	return nil
}
