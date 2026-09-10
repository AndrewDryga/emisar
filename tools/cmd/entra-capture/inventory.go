package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// What this rig has left in the Entra tenant, and optionally removing it.
//
// The capture flows create objects in TWO places and for a long time had no way
// to say so, which is how leftovers accumulated until the founder found them by
// hand — see .agent/kb/rules/shared-capture-rigs-own-what-they-create.md:
//
//   - app registrations named "emisar" (the registration flow's form — seven
//     duplicates accumulated before the list blade's failure to render made
//     them visible),
//   - enterprise applications such as "emisar SCIM" ("New application" →
//     "Create your own application").
//
// Every object in both collections is printed with a verdict beside it. A
// filter that can silently under-match must show what it looked at; "nothing
// to clean up" from a filter that matched nothing is not evidence of a clean
// tenant.
//
// Graph, not the portal's DOM: the portal renders blades in iframes and its
// list is virtualised; Graph answers the same question directly. The token is
// taken by watching the portal authenticate its OWN calls rather than posting
// to an internal token endpoint whose contract we'd be guessing at — that
// guess returned nothing, and a token fetch that quietly yields '' is one edit
// away from reporting an empty tenant as a clean one.

const graphBase = "https://graph.microsoft.com/v1.0"

var bearer = regexp.MustCompile(`(?i)^bearer `)

// graphToken loads the Enterprise applications blade — the one that lists what
// these flows create, so loading it is what makes the console go and read that
// list — and returns the bearer it used for Graph. The Entra admin center calls
// Graph from the browser; the Azure portal proxies the same reads through its
// own API, so its session never shows a Graph token.
func graphToken(ctx context.Context) (string, error) {
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
		return "", err
	}
	for i := 0; i < 30; i++ {
		mu.Lock()
		found := token
		mu.Unlock()
		if found != "" {
			return found, nil
		}
		if err := chromedp.Run(ctx, chromedp.Sleep(2*time.Second)); err != nil {
			return "", err
		}
	}
	return "", errors.New("could not obtain a Graph token from the portal session — cannot list the tenant\nWITHOUT A LISTING THIS TENANT CANNOT BE CALLED CLEAN")
}

type graphRow struct {
	ID          string `json:"id"`
	AppID       string `json:"appId"`
	DisplayName string `json:"displayName"`
}

type graphCollection struct {
	label, resource, selection string
	mine                       []graphRow
}

// listAll follows @odata.nextLink to the last page. A page cap under-lists
// exactly as silently as a bad filter: 200 rows fit today's tenant, and the day
// they don't, a truncated listing reads as a clean one.
func listAll(ctx context.Context, client *http.Client, token, path string) ([]graphRow, error) {
	var rows []graphRow
	next := graphBase + path
	for next != "" {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, next, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Authorization", token)
		request.Header.Set("Accept", "application/json")
		response, err := client.Do(request)
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

func graphDelete(ctx context.Context, client *http.Client, token, path string) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, graphBase+path, nil)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", token)
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	return response.StatusCode, nil
}

// auditTenant lists every app registration and enterprise application with a
// verdict, and removes the ones that are ours when remove is set. Ours by the
// names these flows use; a keeper is identified by something it carries, never
// by a name the filter happens to miss: the saved walkthrough app registration
// (and its service principal) whose appId is ENTRA_CLIENT_ID, and the SCIM
// enterprise application whose appId is ENTRA_SCIM_APP_ID. The registration,
// app, and provisioning flows resume those by id instead of creating yet
// another duplicate, so deleting either breaks the next capture run — the
// accident okta-capture's filter already had once.
func auditTenant(ctx context.Context, env map[string]string, remove bool) error {
	if err := chromedp.Run(ctx, chromedp.EmulateViewport(1520, 950)); err != nil {
		return err
	}
	token, err := graphToken(ctx)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 60 * time.Second}
	keeper := func(row graphRow) bool {
		for _, key := range []string{"ENTRA_CLIENT_ID", "ENTRA_SCIM_APP_ID"} {
			if env[key] != "" && row.AppID == env[key] {
				return true
			}
		}
		return false
	}
	ours := func(row graphRow) bool {
		return strings.Contains(strings.ToLower(row.DisplayName), "emisar") && !keeper(row)
	}
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
		rows, err := listAll(ctx, client, token, "/"+section.resource+"?$select="+section.selection+"&$top=200")
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
			status, err := graphDelete(ctx, client, token, "/"+section.resource+"/"+row.ID)
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
