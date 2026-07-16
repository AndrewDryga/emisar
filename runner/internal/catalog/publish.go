package catalog

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"sort"
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
	// addressed path and whose stored bytes were fetched and verified.
	Skipped []string
}

// Publish uploads the artifact tree at dir (as described by its
// manifest.json) to opts.Bucket. Immutable objects are uploaded with an
// if-generation-match:0 precondition so an existing object is never
// overwritten; after a precondition failure the stored bytes must match before
// the object is skipped. Mutable pointers are overwritten (the bucket's object
// versioning retains prior generations).
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

	// Upload immutable objects (content-addressed tarballs/snapshots and
	// explicitly versioned schemas) BEFORE the mutable pointers (catalog.json /
	// latest) that reference them, so a mid-publish failure never leaves the live
	// pointer resolving to a 404 tarball. Stable so objects of the same class keep
	// their manifest order.
	sort.SliceStable(m.Objects, func(i, j int) bool {
		return m.Objects[i].Immutable && !m.Objects[j].Immutable
	})

	res := &PublishResult{}
	for _, obj := range m.Objects {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(obj.Path)))
		if err != nil {
			return nil, fmt.Errorf("catalog: read object %s: %w", obj.Path, err)
		}
		// Verify the bytes against the manifest before uploading — a stale or
		// partial dist tree would otherwise write WRONG bytes to an immutable,
		// content-addressed path that can never be corrected. Rebuild, don't push.
		if got := hex.EncodeToString(sha256Sum(data)); got != obj.SHA256 {
			return nil, fmt.Errorf(
				"catalog: object %s sha256 mismatch (manifest=%s on-disk=%s) — stale or partial dist tree; rebuild before publishing",
				obj.Path, obj.SHA256, got)
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

// putObject uploads one object via the GCS JSON multipart-upload API. It returns
// (true, nil) on a successful upload, (false, nil) when an immutable object
// already exists (precondition failed), and an error otherwise.
func putObject(ctx context.Context, client *http.Client, endpoint, token, bucket string, obj Object, data []byte) (bool, error) {
	q := url.Values{}
	q.Set("uploadType", "multipart")
	if obj.Immutable {
		q.Set("ifGenerationMatch", "0")
	}
	uploadURL := fmt.Sprintf("%s/upload/storage/v1/b/%s/o?%s", endpoint, url.PathEscape(bucket), q.Encode())

	var uploadBody bytes.Buffer
	writer := multipart.NewWriter(&uploadBody)
	metadataHeader := make(textproto.MIMEHeader)
	metadataHeader.Set("Content-Type", "application/json; charset=UTF-8")
	metadataPart, err := writer.CreatePart(metadataHeader)
	if err != nil {
		return false, fmt.Errorf("catalog: create metadata part for %s: %w", obj.Path, err)
	}
	cacheControl := "no-store"
	if obj.Immutable {
		cacheControl = "public, max-age=31536000, immutable"
	}
	metadata := struct {
		Name         string `json:"name"`
		ContentType  string `json:"contentType"`
		CacheControl string `json:"cacheControl"`
	}{obj.Path, obj.ContentType, cacheControl}
	if err := json.NewEncoder(metadataPart).Encode(metadata); err != nil {
		return false, fmt.Errorf("catalog: encode metadata for %s: %w", obj.Path, err)
	}
	dataHeader := make(textproto.MIMEHeader)
	dataHeader.Set("Content-Type", obj.ContentType)
	dataPart, err := writer.CreatePart(dataHeader)
	if err != nil {
		return false, fmt.Errorf("catalog: create data part for %s: %w", obj.Path, err)
	}
	if _, err := dataPart.Write(data); err != nil {
		return false, fmt.Errorf("catalog: encode data for %s: %w", obj.Path, err)
	}
	if err := writer.Close(); err != nil {
		return false, fmt.Errorf("catalog: finish upload body for %s: %w", obj.Path, err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, &uploadBody)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "multipart/related; boundary="+writer.Boundary())

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
		stored, err := getObject(ctx, client, endpoint, bucket, obj.Path, len(data))
		if err != nil {
			return false, fmt.Errorf("catalog: verify existing immutable object %s: %w", obj.Path, err)
		}
		if !bytes.Equal(stored, data) {
			return false, fmt.Errorf(
				"catalog: immutable object %s already exists with different bytes (expected sha256 %s, stored sha256 %s)",
				obj.Path, hex.EncodeToString(sha256Sum(data)), hex.EncodeToString(sha256Sum(stored)))
		}
		return false, nil
	default:
		return false, fmt.Errorf("catalog: upload %s: HTTP %d: %s", obj.Path, resp.StatusCode, string(body))
	}
}

func getObject(ctx context.Context, client *http.Client, endpoint, bucket, name string, expectedSize int) ([]byte, error) {
	objectURL := fmt.Sprintf("%s/storage/v1/b/%s/o/%s?alt=media",
		endpoint, url.PathEscape(bucket), url.PathEscape(name))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, objectURL, nil)
	if err != nil {
		return nil, fmt.Errorf("build GET request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return nil, fmt.Errorf("GET returned HTTP %d: %s", resp.StatusCode, string(body))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, int64(expectedSize)+1))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if len(data) > expectedSize {
		return nil, fmt.Errorf("stored object exceeds expected size of %d bytes", expectedSize)
	}
	return data, nil
}
