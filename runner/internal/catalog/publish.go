package catalog

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

// DefaultGCSEndpoint is the Google Cloud Storage JSON API base. Overridable
// (PublishOptions.Endpoint) so tests can point at an httptest server.
const DefaultGCSEndpoint = "https://storage.googleapis.com"

// PublishOptions parameterizes uploading a built tree to a GCS bucket.
type PublishOptions struct {
	// Bucket is the target GCS bucket (e.g. emisar-pack-registry).
	Bucket string
	// Token is the OAuth2 access token uploads authenticate with. Required
	// unless DryRun. In CI it comes from Workload Identity; locally from
	// `gcloud auth print-access-token`.
	Token string
	// Endpoint defaults to DefaultGCSEndpoint.
	Endpoint string
	// HTTPClient defaults to a 60s-timeout client.
	HTTPClient *http.Client
	// DryRun logs what would be uploaded without contacting GCS.
	DryRun bool
	// Logf receives one progress line per object. Defaults to no-op.
	Logf func(format string, args ...any)
}

// PublishResult summarizes a publish run.
type PublishResult struct {
	Uploaded []string
	// Skipped are immutable objects that already existed at their content-
	// addressed path (if-generation-match precondition failed) — expected
	// and safe: identical bytes, so a republish is a no-op.
	Skipped []string
}

// Publish uploads the artifact tree at dir (as described by its
// manifest.json) to opts.Bucket. Immutable objects are uploaded with an
// if-generation-match:0 precondition so an existing object is never
// overwritten; a precondition failure means the identical object is already
// published and is skipped. Mutable pointers are overwritten (the bucket's
// object versioning retains prior generations).
func Publish(ctx context.Context, dir string, opts PublishOptions) (*PublishResult, error) {
	if opts.Bucket == "" {
		return nil, fmt.Errorf("catalog: publish requires a bucket")
	}
	if opts.Token == "" && !opts.DryRun {
		return nil, fmt.Errorf("catalog: publish requires an access token (set GOOGLE_OAUTH_ACCESS_TOKEN)")
	}
	logf := opts.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	endpoint := opts.Endpoint
	if endpoint == "" {
		endpoint = DefaultGCSEndpoint
	}
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 60 * time.Second}
	}

	manifestBytes, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("catalog: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(manifestBytes, &m); err != nil {
		return nil, fmt.Errorf("catalog: parse manifest: %w", err)
	}

	res := &PublishResult{}
	for _, obj := range m.Objects {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(obj.Path)))
		if err != nil {
			return nil, fmt.Errorf("catalog: read object %s: %w", obj.Path, err)
		}
		if opts.DryRun {
			logf("would upload %s (%d bytes, immutable=%v)", obj.Path, len(data), obj.Immutable)
			res.Uploaded = append(res.Uploaded, obj.Path)
			continue
		}
		uploaded, err := putObject(ctx, client, endpoint, opts.Token, opts.Bucket, obj, data)
		if err != nil {
			return nil, err
		}
		if uploaded {
			logf("uploaded %s (%d bytes)", obj.Path, len(data))
			res.Uploaded = append(res.Uploaded, obj.Path)
		} else {
			logf("skipped %s (already published, identical bytes)", obj.Path)
			res.Skipped = append(res.Skipped, obj.Path)
		}
	}
	return res, nil
}

// putObject uploads one object via the GCS JSON media-upload API. It returns
// (true, nil) on a successful upload, (false, nil) when an immutable object
// already exists (precondition failed), and an error otherwise.
func putObject(ctx context.Context, client *http.Client, endpoint, token, bucket string, obj Object, data []byte) (bool, error) {
	q := url.Values{}
	q.Set("uploadType", "media")
	q.Set("name", obj.Path)
	if obj.Immutable {
		q.Set("ifGenerationMatch", "0")
	}
	uploadURL := fmt.Sprintf("%s/upload/storage/v1/b/%s/o?%s", endpoint, url.PathEscape(bucket), q.Encode())

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, bytes.NewReader(data))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", obj.ContentType)

	resp, err := client.Do(req)
	if err != nil {
		return false, fmt.Errorf("catalog: upload %s: %w", obj.Path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return true, nil
	case resp.StatusCode == http.StatusPreconditionFailed && obj.Immutable:
		// Object already exists at its content-addressed path — identical
		// bytes, so this is the expected idempotent-republish path.
		return false, nil
	default:
		return false, fmt.Errorf("catalog: upload %s: HTTP %d: %s", obj.Path, resp.StatusCode, string(body))
	}
}
