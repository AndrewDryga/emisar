package ci

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"testing"
)

func TestNormalizeEd25519Seed(t *testing.T) {
	seed := bytes.Repeat([]byte{0xab}, ed25519.SeedSize)
	hexSeed := hex.EncodeToString(seed)
	if got, err := NormalizeEd25519Seed(stringsUpper(hexSeed)); err != nil || got != hexSeed {
		t.Fatalf("hex seed = %q, %v", got, err)
	}
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if got, err := NormalizeEd25519Seed(string(pemKey)); err != nil || got != hex.EncodeToString(privateKey.Seed()) {
		t.Fatalf("PEM seed = %q, %v", got, err)
	}
	for _, invalid := range []string{"", "abcd", string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("bad")}))} {
		if _, err := NormalizeEd25519Seed(invalid); err == nil {
			t.Fatalf("invalid key %q passed", invalid)
		}
	}
}

func TestPublisherBinary(t *testing.T) {
	archive := tarGzip(t, map[string]string{"README": "ignore", "mcp-publisher": "binary"})
	got, err := publisherBinary(archive)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "binary" {
		t.Fatalf("publisher = %q", got)
	}
	if _, err := publisherBinary(tarGzip(t, map[string]string{"other": "no"})); err == nil {
		t.Fatal("archive without publisher passed")
	}
}

func tarGzip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var data bytes.Buffer
	gzipWriter := gzip.NewWriter(&data)
	tarWriter := tar.NewWriter(gzipWriter)
	for name, contents := range files {
		if err := tarWriter.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(contents)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tarWriter.Write([]byte(contents)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}

func stringsUpper(value string) string {
	result := []byte(value)
	for index, character := range result {
		if character >= 'a' && character <= 'f' {
			result[index] = character - ('a' - 'A')
		}
	}
	return string(result)
}
