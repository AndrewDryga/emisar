package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/catalog"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// defaultRegistryBaseURL is the public HTTPS base pack artifacts are served
// from — the vendor-neutral serving domain (infra: an LB host rule fronts the
// GCS bucket, packs_registry.tf). Tarball URLs in the built catalog join paths
// onto it. The bucket still serves the SAME bytes at
// storage.googleapis.com/emisar-pack-registry, so old published URLs keep
// resolving; override with --base-url to build against a different base.
const defaultRegistryBaseURL = "https://registry.emisar.dev"

func packCatalogCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "catalog",
		Short: "Build and publish a versioned pack registry",
		Long: `Build a publishable pack registry from a packs directory, and upload it.

Works for ANY registry, not just emisar's: point --base-url at wherever you
host it and 'publish' to your own GCS bucket — or skip 'publish' and sync the
built tree to S3, MinIO, or any static file host (it is plain files). Runners
install from it with 'emisar pack install <id> --registry <your-base-url>'.
Guide: https://emisar.dev/docs/pack-registry

'build' produces, under an output dir, the immutable per-pack tarballs
(content-addressed), catalog.json + a content-addressed snapshot,
suggest.json, and the JSON schemas — all hashed with the same loader the
runner uses, so the published content hash matches 'emisar pack validate'
byte-for-byte. 'publish' uploads that tree to GCS, never overwriting an
immutable object.`,
	}
	cmd.AddCommand(packCatalogBuildCmd())
	cmd.AddCommand(packCatalogPublishCmd())
	return cmd
}

func packCatalogBuildCmd() *cobra.Command {
	var (
		packsDir    string
		outDir      string
		baseURL     string
		repoURL     string
		previous    string
		retireOlder []string
	)
	cmd := &cobra.Command{
		Use:   "build",
		Short: "Build the pack registry artifact tree from a packs directory",
		Long: `Validate every pack through the runner's loader/hash path and write the
publishable artifact tree to --out:

  v1/catalog.json                                  latest catalog (mutable pointer)
  v1/catalog/<sha256>.json                         immutable catalog snapshot
  v1/suggest.json                                  lean suggest index (mutable pointer)
  v1/schemas/*.json                                catalog + authoring schemas
  v1/packs/<id>/<version>/<sha256>/pack.tar.gz     immutable pack tarball
  manifest.json                                    upload plan (not published)

Pass --previous <catalog.json> (the currently-published catalog) to enforce
the "preserve every version/hash" guarantee: the build fails if any pack
changed bytes for an already-published id+version — bump the version instead.
--previous also carries each pack's prior versions forward into its trust
window (previous_versions) and its retirement watermark.

Pass --retire-older <pack-id> (repeatable) on a critical fix to retire every
older version of that pack in one operation: its retired_below is set to the
current version and its carried history is cleared. Requires --previous.

  packctl catalog build --packs ./packs --out ./dist
  packctl catalog build --packs ./packs --out ./dist --previous ./current-catalog.json
  packctl catalog build --packs ./packs --out ./dist --previous ./current-catalog.json --retire-older redis`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			reg, err := packs.LoadAll([]string{packsDir}, packs.LoadOptions{})
			if err != nil {
				return err
			}
			if len(reg.Packs()) == 0 {
				return fmt.Errorf("no packs found in %s", packsDir)
			}

			if len(retireOlder) > 0 && previous == "" {
				return fmt.Errorf("--retire-older requires --previous (retirement is applied against the currently-published catalog)")
			}
			opts := catalog.BuildOptions{BaseURL: baseURL, RepoURL: repoURL, RetireOlder: retireOlder}
			if previous != "" {
				prev, err := loadPreviousCatalog(previous)
				if err != nil {
					return err
				}
				opts.Previous = prev
			}

			cat, err := catalog.Build(reg, opts)
			if err != nil {
				return err
			}
			manifest, err := catalog.Write(reg, cat, outDir)
			if err != nil {
				return err
			}

			if flagJSONOut {
				return printJSON(manifest)
			}
			banner("built %d packs → %s (catalog %s, %d objects)",
				len(cat.Packs), outDir, manifest.CatalogHash[:12], len(manifest.Objects))
			return nil
		},
	}
	cmd.Flags().StringVar(&packsDir, "packs", "packs", "packs directory to build from")
	cmd.Flags().StringVar(&outDir, "out", "dist", "output directory for the artifact tree")
	cmd.Flags().StringVar(&baseURL, "base-url", defaultRegistryBaseURL, "public base URL tarball URLs join onto")
	cmd.Flags().StringVar(&repoURL, "repo-url", catalog.DefaultRepoURL, "source repository URL for source links")
	cmd.Flags().StringVar(&previous, "previous", "", "currently-published catalog.json to check version/hash drift against and carry version history forward from")
	cmd.Flags().StringArrayVar(&retireOlder, "retire-older", nil, "pack id to retire all older versions of (repeatable; requires --previous)")
	return cmd
}

func packCatalogPublishCmd() *cobra.Command {
	var (
		dir      string
		bucket   string
		endpoint string
		dryRun   bool
	)
	cmd := &cobra.Command{
		Use:   "publish",
		Short: "Upload a built artifact tree to a GCS registry bucket",
		Long: `Upload the artifact tree produced by 'build' to a GCS bucket — emisar's
public one or your own. Immutable objects (tarballs, catalog snapshots,
schemas) are uploaded with an if-generation-match:0 precondition, so an
existing object is never overwritten — a precondition failure means the
identical bytes are already published and the object is skipped. The mutable
pointers (catalog.json, suggest.json) are overwritten; enable object
versioning on the bucket to retain every prior generation.

Hosting somewhere else (S3, MinIO, plain nginx)? Skip 'publish' and sync the
built --out tree there with any tool — it is plain static files; just upload
immutable objects before the two mutable pointers.

Authentication uses an OAuth2 access token from GOOGLE_OAUTH_ACCESS_TOKEN
(in CI from Workload Identity; locally 'gcloud auth print-access-token').

  GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) \
    packctl catalog publish --dir ./dist --bucket my-pack-registry
  packctl catalog publish --dir ./dist --bucket my-pack-registry --dry-run`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts := catalog.PublishOptions{
				Bucket:   bucket,
				Token:    os.Getenv("GOOGLE_OAUTH_ACCESS_TOKEN"),
				Endpoint: endpoint,
				DryRun:   dryRun,
				Logf:     banner,
			}
			res, err := catalog.Publish(cmd.Context(), dir, opts)
			if err != nil {
				return err
			}
			if flagJSONOut {
				return printJSON(res)
			}
			banner("published %d objects (%d skipped, already present)", len(res.Uploaded), len(res.Skipped))
			return nil
		},
	}
	cmd.Flags().StringVar(&dir, "dir", "dist", "built artifact tree (from 'build') to upload")
	cmd.Flags().StringVar(&bucket, "bucket", "emisar-pack-registry", "target GCS bucket")
	cmd.Flags().StringVar(&endpoint, "endpoint", "", "GCS JSON API endpoint (default "+catalog.DefaultGCSEndpoint+")")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the upload plan without contacting GCS")
	return cmd
}

func loadPreviousCatalog(path string) (*catalog.Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read previous catalog %s: %w", path, err)
	}
	var prev catalog.Catalog
	if err := json.Unmarshal(data, &prev); err != nil {
		return nil, fmt.Errorf("parse previous catalog %s: %w", path, err)
	}
	return &prev, nil
}
