package ci

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	publisherVersion = "1.8.0"
	publisherSHA256  = "1370446bbe74d562608e8005a6ccce02d146a661fbd78674e11cc70b9618d6cf"
	publisherURL     = "https://github.com/modelcontextprotocol/registry/releases/download/v" + publisherVersion + "/mcp-publisher_linux_amd64.tar.gz"
)

func InstallMCPPublisher(ctx context.Context, destination string) error {
	client := &http.Client{Timeout: 2 * time.Minute}
	var response *http.Response
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, publisherURL, nil)
		if requestErr != nil {
			return requestErr
		}
		response, err = client.Do(request)
		if err == nil && response.StatusCode == http.StatusOK {
			break
		}
		if response != nil {
			response.Body.Close()
			err = fmt.Errorf("download returned %s", response.Status)
		}
		if attempt < 3 {
			time.Sleep(2 * time.Second)
		}
	}
	if err != nil {
		return fmt.Errorf("download mcp-publisher: %w", err)
	}
	defer response.Body.Close()
	archive, err := io.ReadAll(io.LimitReader(response.Body, 100<<20))
	if err != nil {
		return err
	}
	digest := sha256.Sum256(archive)
	if hex.EncodeToString(digest[:]) != publisherSHA256 {
		return fmt.Errorf("mcp-publisher checksum mismatch")
	}
	binary, err := publisherBinary(archive)
	if err != nil {
		return err
	}
	return installExecutable(destination, binary)
}

func publisherBinary(archive []byte) ([]byte, error) {
	gzipReader, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, fmt.Errorf("open mcp-publisher archive: %w", err)
	}
	defer gzipReader.Close()
	tarReader := tar.NewReader(gzipReader)
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read mcp-publisher archive: %w", err)
		}
		if header.Name != "mcp-publisher" {
			continue
		}
		return io.ReadAll(tarReader)
	}
	return nil, fmt.Errorf("mcp-publisher archive does not contain mcp-publisher")
}

func installExecutable(destination string, contents []byte) error {
	directory := filepath.Dir(destination)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".mcp-publisher-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o755); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, destination)
}

func NormalizeEd25519Seed(key string) (string, error) {
	key = strings.TrimSpace(key)
	if key == "" {
		return "", fmt.Errorf("MCP_PRIVATE_KEY is not configured")
	}
	if decoded, err := hex.DecodeString(key); err == nil && len(decoded) == 32 {
		return hex.EncodeToString(decoded), nil
	}
	block, _ := pem.Decode([]byte(key))
	if block == nil {
		return "", fmt.Errorf("MCP_PRIVATE_KEY must be a 64-character Ed25519 hex seed or a valid PKCS#8 PEM private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("MCP_PRIVATE_KEY must be a 64-character Ed25519 hex seed or a valid PKCS#8 PEM private key")
	}
	privateKey, ok := parsed.(ed25519.PrivateKey)
	if !ok || len(privateKey) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("MCP_PRIVATE_KEY PEM does not contain an Ed25519 private key")
	}
	return hex.EncodeToString(privateKey.Seed()), nil
}
