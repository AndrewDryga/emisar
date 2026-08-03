package packhash

import "testing"

func TestParseGoldens(t *testing.T) {
	t.Parallel()
	data := []byte(`
assert PublishedRegistry.get("redis").content_hash ==
         "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

assert PublishedRegistry.get("cassandra").content_hash ==
         "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
`)
	got, err := parseGoldens(data)
	if err != nil {
		t.Fatal(err)
	}
	if got["redis"].hash != "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatalf("redis hash = %q", got["redis"].hash)
	}
	if got["cassandra"].hash != "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("cassandra hash = %q", got["cassandra"].hash)
	}
}
