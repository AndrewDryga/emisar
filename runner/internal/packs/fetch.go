package packs

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
)

// Fetch limits — packs are tiny (tens of KB), so these are generous
// ceilings that exist only to bound a hostile or corrupt response
// (decompression bomb, runaway entry count) rather than to constrain
// legitimate packs.
const (
	maxPackBytes   = 32 << 20 // 32 MiB total uncompressed
	maxPackFiles   = 4000
	maxSingleBytes = 8 << 20 // 8 MiB per file
)

// Fetch downloads a gzip-compressed tarball of a pack from srcURL and
// extracts it into a fresh temp directory. The returned dir contains the
// pack's files at its root (pack.yaml, actions/…) ready for LoadOne. The
// caller MUST invoke cleanup when done to remove the temp tree.
//
// The HTTP transport and timeout are the caller's; redirect security is always
// enforced. A nil client defaults to a 30s timeout.
func Fetch(ctx context.Context, srcURL string, client *http.Client) (dir string, cleanup func(), err error) {
	// Defense-in-depth: never pull pack bytes over cleartext http from a remote
	// host (a MITM could serve poisoned bytes — the pack hash is re-verified, but
	// don't even fetch them). Loopback is allowed for a local dev registry.
	if err := config.CheckEndpointScheme(srcURL, false); err != nil {
		return "", nil, fmt.Errorf("packs: %w", err)
	}

	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	client = secureFetchClient(client)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srcURL, nil)
	if err != nil {
		return "", nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", nil, fmt.Errorf("packs: fetch %s: %w", srcURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "", nil, fmt.Errorf("packs: %s not found (404) — check the pack name and registry", srcURL)
	}
	if resp.StatusCode != http.StatusOK {
		return "", nil, fmt.Errorf("packs: fetch %s returned %d", srcURL, resp.StatusCode)
	}

	tmp, err := os.MkdirTemp("", "emisar-pack-*")
	if err != nil {
		return "", nil, err
	}
	cleanup = func() { _ = os.RemoveAll(tmp) }

	if err := extractTarGz(resp.Body, tmp); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("packs: extract %s: %w", srcURL, err)
	}
	return tmp, cleanup, nil
}

func secureFetchClient(base *http.Client) *http.Client {
	client := *httpsecurity.ClientWithTLS12(base)
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("packs: stopped after 10 redirects")
		}
		if err := config.CheckEndpointScheme(req.URL.String(), false); err != nil {
			return fmt.Errorf("packs: redirect refused: %w", err)
		}
		if len(via) > 0 && via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
			return errors.New("packs: redirect refused HTTPS downgrade")
		}
		return nil
	}
	return &client
}

// extractTarGz unpacks a gzip-compressed tar stream into dest. It is the
// trust boundary for a downloaded pack: every entry name is validated to
// stay under dest (no absolute paths, no `..` traversal), only regular
// files and directories are written (no symlinks/devices/hardlinks), and
// total + per-file + entry-count limits bound a decompression bomb.
func extractTarGz(r io.Reader, dest string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return fmt.Errorf("gzip: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	var total int64
	var files int

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar: %w", err)
		}

		files++
		if files > maxPackFiles {
			return fmt.Errorf("too many entries (> %d)", maxPackFiles)
		}

		out, err := safeJoin(dest, hdr.Name)
		if err != nil {
			return err
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(out, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if hdr.Size > maxSingleBytes {
				return fmt.Errorf("entry %s too large (%d bytes)", hdr.Name, hdr.Size)
			}
			if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
			if err != nil {
				return err
			}
			// LimitReader caps a single oversized/streaming entry; the
			// running total caps the whole archive.
			n, err := io.Copy(f, io.LimitReader(tr, maxSingleBytes+1))
			f.Close()
			if err != nil {
				return err
			}
			if n > maxSingleBytes {
				return fmt.Errorf("entry %s exceeded size limit", hdr.Name)
			}
			total += n
			if total > maxPackBytes {
				return fmt.Errorf("archive exceeded total size limit (%d bytes)", maxPackBytes)
			}
		default:
			// Reject symlinks, hardlinks, devices, fifos — a pack is
			// plain files. (Packs that legitimately need symlinks set
			// allow_symlinks and ship them as part of a local dir, not
			// over the fetch path.)
			return fmt.Errorf("entry %s has unsupported type %d", hdr.Name, hdr.Typeflag)
		}
	}
	return nil
}

// safeJoin cleans name and joins it under root, rejecting absolute paths
// and any result that escapes root.
func safeJoin(root, name string) (string, error) {
	if name == "" {
		return "", fmt.Errorf("empty entry name")
	}
	if filepath.IsAbs(name) || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("absolute path entry %q rejected", name)
	}
	clean := filepath.Clean(name)
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path traversal entry %q rejected", name)
	}
	out := filepath.Join(root, clean)
	// Belt-and-suspenders: confirm the joined path is still under root.
	rel, err := filepath.Rel(root, out)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("entry %q escapes pack root", name)
	}
	return out, nil
}
