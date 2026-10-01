package devtool

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// packRegistryCatalogURL is the published catalog at the registry's canonical
// serving domain, the same document `pack sync` regenerates against.
const packRegistryCatalogURL = "https://registry.emisar.dev/v1/catalog.json"

// maxPublishedPackCatalogBytes bounds the read of that catalog. The document is
// a few megabytes; the bound only keeps a wrong response from being read
// without limit.
const maxPublishedPackCatalogBytes = 64 << 20

// checkPackRegistryPublish rehearses CD's packs-publish job against the live
// registry, with reads alone. It builds the registry tree against the published
// catalog as that job does, requires the result to be the committed catalog,
// and has the publisher compare every immutable object with the copy the
// registry already stores. Each of those was first decided by the publish job
// itself, after main had moved: a schema edited without a new
// SchemaArtifactVersion failed it three times in one day. It runs from
// validatePacks for the reason checkCatalogReproduction does — CI reaches packs
// through `./run check packs` — so a green run here is what that job will find.
//
// A registry that publishes no catalog, or one packctl rejects, is rehearsed
// against the committed catalog, which is how the job repairs that state.
// Refusing it here would keep CI red, and the publication that repairs it runs
// only after CI passes.
func (a *App) checkPackRegistryPublish(ctx context.Context) error {
	fmt.Fprintf(a.Out, "\n==> pack registry publish rehearsal\n")
	packctl := filepath.Join(a.Root, "bin", "packctl")
	committed := filepath.Join(a.Portal, "apps", "emisar", "priv", "packs", "catalog.json")

	published, found, err := publishedPackCatalog(ctx, packRegistryCatalogURL)
	if err != nil {
		return fmt.Errorf("the publish rehearsal reads the live pack registry and could not: %w", err)
	}
	work, err := os.MkdirTemp("", "emisar-pack-publish-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)

	previous := committed
	if !found {
		fmt.Fprintln(a.Out, "the registry publishes no catalog; rehearsing against the committed one, as the publication that restores it does")
	} else {
		live := filepath.Join(work, "published-catalog.json")
		if err := os.WriteFile(live, published, 0o600); err != nil {
			return err
		}
		if err := a.run(ctx, a.Root, nil, packctl, "catalog", "validate", live); err != nil {
			fmt.Fprintln(a.Out, "the published catalog is malformed; rehearsing against the committed one, as the publication that repairs it does")
		} else {
			previous = live
		}
	}

	output := filepath.Join(work, "dist")
	if err := a.run(ctx, a.Root, nil, packctl,
		"catalog", "build", "--packs", filepath.Join(a.Root, "packs"), "--out", output, "--previous", previous); err != nil {
		return err
	}
	generated, err := os.ReadFile(filepath.Join(output, "v1", "catalog.json"))
	if err != nil {
		return err
	}
	current, err := os.ReadFile(committed)
	if err != nil {
		return err
	}
	if !bytes.Equal(generated, current) {
		return fmt.Errorf("the registry tree built against the published catalog is not the committed catalog. " +
			"A checkout behind the registry, where a pack is already published at a newer version, needs updating and not a sync. " +
			"Otherwise regenerate the catalog against the registry: ./run pack sync <changed-pack> --fix")
	}
	return a.run(ctx, a.Root, nil, packctl, "catalog", "publish", "--dir", output, "--check")
}

// publishedPackCatalog reads the registry's published catalog. found is false
// when the registry answers 404: nothing is published at that path, which is a
// state the next publication repairs rather than a failure to read. A redirect
// is refused, as the workflows' plain curl refuses it.
func publishedPackCatalog(ctx context.Context, url string) (catalog []byte, found bool, err error) {
	client := &http.Client{
		Timeout: time.Minute,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, false, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, false, err
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return nil, false, nil
	default:
		return nil, false, fmt.Errorf("GET %s: HTTP %s", url, response.Status)
	}
	catalog, err = io.ReadAll(io.LimitReader(response.Body, maxPublishedPackCatalogBytes+1))
	if err != nil {
		return nil, false, fmt.Errorf("GET %s: %w", url, err)
	}
	if len(catalog) > maxPublishedPackCatalogBytes {
		return nil, false, fmt.Errorf("GET %s: the catalog is larger than %d bytes", url, maxPublishedPackCatalogBytes)
	}
	return catalog, true, nil
}
