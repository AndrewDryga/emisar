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
// GCS bucket, pack_registry.tf). Tarball URLs in the built catalog join paths
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
install the exact immutable tarball URL listed in v1/catalog.json. The
name-based '--registry' install flow uses a different URL layout.
Guide: https://emisar.dev/docs/pack-registry

'build' produces, under an output dir, the immutable per-pack tarballs
(content-addressed), catalog.json + a content-addressed snapshot,
suggest.json, and the JSON schemas — all hashed with the same loader the
runner uses, so the published content hash matches 'emisar pack validate'
byte-for-byte. 'publish' uploads that tree to GCS, never overwriting an
immutable object.`,
		// A group command with no RunE is "not runnable", so cobra answers a
		// MISTYPED subcommand ('catalog buld') with help on stdout and exit 0 —
		// a typo in CI reads as success. NoArgs turns an unrecognized argument
		// into an error (exit 1); bare 'catalog' still prints help.
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	cmd.AddCommand(packCatalogBuildCmd())
	cmd.AddCommand(packCatalogPublishCmd())
	cmd.AddCommand(packCatalogValidateCmd())
	return cmd
}

func packCatalogBuildCmd() *cobra.Command {
	var (
		packsDir string
		outDir   string
		baseURL  string
		repoURL  string
		previous string
	)
	cmd := &cobra.Command{
		Use:   "build",
		Short: "Build the pack registry artifact tree from a packs directory",
		Long: `Validate every pack through the runner's loader/hash path and write the
publishable artifact tree to --out:

  v1/catalog.json                                  latest catalog (mutable pointer)
  v1/catalog/<sha256>.json                         immutable catalog snapshot
  v1/suggest.json                                  lean suggest index (mutable pointer)
  packs.json                                       catalog facade alias (mutable pointer)
  packs/suggest.json                               suggest facade alias (mutable pointer)
  v1/schemas/*.vN.schema.json                      immutable versioned schemas
  v1/packs/<id>/<version>/<sha256>/pack.tar.gz     immutable pack tarball
  manifest.json                                    upload plan (not published)

Pass --previous <catalog.json> (the currently-published catalog) to enforce
the "preserve every version/hash" guarantee: the build fails if any pack
changed bytes for an already-published id+version — bump the version instead.
--previous also carries each pack's prior versions forward into its trust
window (previous_versions) and enforces its retirement floor (retired_below):
that floor is authored in the pack.yaml itself, and the build refuses to lower
or drop an already-published one.

  packctl catalog build --packs ./packs --out ./dist
  packctl catalog build --packs ./packs --out ./dist --previous ./current-catalog.json`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			reg, err := packs.LoadAll([]string{packsDir}, packs.LoadOptions{})
			if err != nil {
				return err
			}
			if len(reg.Packs()) == 0 {
				return fmt.Errorf("no packs found in %s", packsDir)
			}

			opts := catalog.BuildOptions{BaseURL: baseURL, RepoURL: repoURL}
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
	cmd.Flags().StringVar(&previous, "previous", "", "currently-published catalog.json to check version/hash drift against and carry version history forward from")
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
identical bytes are already published and the object is skipped. The four
mutable pointer objects (the catalog and suggest documents at their versioned
and facade paths) are overwritten; enable object versioning on the bucket to
retain prior generations.

Hosting somewhere else (S3, MinIO, plain nginx)? Skip 'publish' and upload the
objects listed in manifest.json with any tool. Upload immutable objects before
the four mutable pointers, keep v1/catalog.json last, and do not publish the
manifest itself.

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
			// A dry run contacts nothing, so it reports what WOULD be uploaded:
			// "published N objects" after talking to no bucket is a lie an
			// operator acts on.
			if dryRun {
				banner("dry run: %d objects would be uploaded", len(res.Uploaded))
				return nil
			}
			banner("published %d objects (%d skipped, already present)", len(res.Uploaded), len(res.Skipped))
			return nil
		},
	}
	cmd.Flags().StringVar(&dir, "dir", "dist", "built artifact tree (from 'build') to upload")
	cmd.Flags().StringVar(&bucket, "bucket", "emisar-pack-registry", "target GCS bucket")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the upload plan without contacting GCS")
	return cmd
}

func loadPreviousCatalog(path string) (*catalog.Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read previous catalog %s: %w", path, err)
	}
	// Validate against the published schema BEFORE unmarshalling into the
	// struct. A subtly corrupt catalog — packs dropped, previous_versions
	// truncated — still unmarshals cleanly, and carryForward then hands the
	// missing packs an empty history while checkDrift permits versions to
	// vanish. The result is a silently amputated version window.
	if err := catalog.ValidateCatalogDocument(data); err != nil {
		return nil, fmt.Errorf("previous catalog %s: %w", path, err)
	}

	var prev catalog.Catalog
	if err := json.Unmarshal(data, &prev); err != nil {
		return nil, fmt.Errorf("parse previous catalog %s: %w", path, err)
	}
	return &prev, nil
}

// packCatalogValidateCmd exists so CI can ask the SAME question 'build
// --previous' asks. Before it, cd.yml decided whether a downloaded catalog was
// usable with a jq predicate (schema_version == 1 and a non-empty packs array)
// while packctl accepted anything that unmarshalled. Two different answers to
// one question is how a corrupt-but-parseable catalog gets carried forward:
// the workflow judges it good enough to pass as --previous, and packctl agrees
// because it barely looks.
func packCatalogValidateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate <catalog.json>",
		Short: "Check a catalog document against the published catalog schema",
		Long: `Validate a catalog.json against the schema published alongside it — the
same check 'build --previous' applies before accepting a history.

Use it in automation to decide whether a downloaded catalog is usable before
passing it as --previous. Exits non-zero with the schema violation on stderr.

This is a structural check, not a trust decision: pack authenticity remains the
content hash over pack bytes.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			data, err := os.ReadFile(args[0])
			if err != nil {
				return fmt.Errorf("read catalog %s: %w", args[0], err)
			}
			if err := catalog.ValidateCatalogDocument(data); err != nil {
				return fmt.Errorf("%s: %w", args[0], err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s matches the published catalog schema\n", args[0])
			return nil
		},
	}
}
