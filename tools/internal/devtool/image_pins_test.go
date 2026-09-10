package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	pinnedPostgres = "postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
	pinnedKeycloak = "quay.io/keycloak/keycloak:26.7.0@sha256:0f198be292568439d700cdbfb893e69a6009bb43a94a06a945b1d3d506c76b13"
)

func writeImagePinFixtures(t *testing.T, e2e, dev, review, ci string) *App {
	t.Helper()
	root := t.TempDir()
	for path, body := range map[string]string{
		"docker-compose.yml":        e2e,
		"dev/compose.yml":           dev,
		"dev/review-compose.yml":    review,
		".github/workflows/ci.yml":  ci,
		"packs/x/test/compose.yaml": "services:\n  db:\n    image: postgres:16-alpine\n",
	} {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckSharedServiceImagePins(t *testing.T) {
	e2e := "services:\n  db:\n    # docker buildx imagetools inspect postgres:18.4-alpine\n    image: " + pinnedPostgres +
		"\n  keycloak:\n    image: " + pinnedKeycloak + "\n"
	dev := "services:\n  db:\n    image: " + pinnedPostgres + "\n  keycloak:\n    image: " + pinnedKeycloak + "\n"
	review := "services:\n  db:\n    image: " + pinnedPostgres + "\n"
	ci := "jobs:\n  a:\n    services:\n      postgres:\n        image: &postgres-image " + pinnedPostgres +
		"\n  b:\n    services:\n      postgres:\n        image: *postgres-image\n"

	// Everything agrees; the pack SUT compose is deliberately outside the set.
	if err := writeImagePinFixtures(t, e2e, dev, review, ci).checkSharedServiceImagePins(); err != nil {
		t.Fatal(err)
	}

	// The drift this check was added for: the review stack on a bare tag.
	err := writeImagePinFixtures(t, e2e, dev, "services:\n  db:\n    image: postgres:18.4-alpine\n", ci).
		checkSharedServiceImagePins()
	if err == nil || !strings.Contains(err.Error(), "dev/review-compose.yml:3: postgres:18.4-alpine differs from docker-compose.yml:4") {
		t.Fatalf("unpinned review stack not reported: %v", err)
	}

	// Same digest under a coarser tag is still drift: a version grep misses it.
	coarse := strings.Replace(ci, "postgres:18.4-alpine@", "postgres:18-alpine@", 1)
	err = writeImagePinFixtures(t, e2e, dev, review, coarse).checkSharedServiceImagePins()
	if err == nil || !strings.Contains(err.Error(), ".github/workflows/ci.yml:5: postgres:18-alpine@") {
		t.Fatalf("coarser CI tag not reported: %v", err)
	}

	// Keycloak is checked too, and only where it is declared.
	err = writeImagePinFixtures(t, e2e, strings.Replace(dev, pinnedKeycloak, "quay.io/keycloak/keycloak:26.7.0", 1), review, ci).
		checkSharedServiceImagePins()
	if err == nil || !strings.Contains(err.Error(), "dev/compose.yml:5: quay.io/keycloak/keycloak:26.7.0 differs") {
		t.Fatalf("unpinned keycloak not reported: %v", err)
	}

	// The reference itself losing its digest is reported, not silently trusted.
	bare := strings.Replace(e2e, pinnedPostgres, "postgres:18.4-alpine", 1)
	err = writeImagePinFixtures(t, bare, dev, review, ci).checkSharedServiceImagePins()
	if err == nil || !strings.Contains(err.Error(), "docker-compose.yml:4: postgres:18.4-alpine is not digest-pinned") {
		t.Fatalf("unpinned reference not reported: %v", err)
	}

	// A reference file that stops declaring the image fails loudly.
	err = writeImagePinFixtures(t, "services:\n  db: {}\n", dev, review, ci).checkSharedServiceImagePins()
	if err == nil || !strings.Contains(err.Error(), "docker-compose.yml does not declare postgres") {
		t.Fatalf("missing reference not reported: %v", err)
	}
}
