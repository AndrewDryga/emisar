package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// The offline policy evidence the Python gate ran as `self-test` on every CI
// run lives here as regular tests instead: the runner CI test job proves the
// logic whenever this code changes, and the deps job just runs `check`.

const npmLockFixture = `{
  "lockfileVersion": 3,
  "packages": {
    "": {"name": "tooling"},
    "node_modules/puppeteer-core": {
      "version": "25.2.0",
      "resolved": "https://registry.npmjs.org/puppeteer-core/-/puppeteer-core-25.2.0.tgz"
    },
    "node_modules/@scoped/pkg": {
      "version": "1.0.0",
      "resolved": "https://registry.npmjs.org/@scoped/pkg/-/pkg-1.0.0.tgz"
    },
    "node_modules/evil": {"version": "1.0.0", "resolved": "git+https://x/evil.git#abc"},
    "node_modules/local": {"version": "0.0.1", "link": true}
  }
}`

func TestParseHex_SkipsGitAndPathEntries(t *testing.T) {
	lock := `  "plug": {:hex, :plug, "1.18.0", "hash", [:mix], [], "hexpm", "h"},
  "some_git": {:git, "https://x", "ref", []},
`
	got := parseHex(lock)
	want := map[string]string{"plug": "1.18.0"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseHex = %v, want %v", got, want)
	}
}

func TestParseGo_BlockSingleLineAndIndirect(t *testing.T) {
	goMod := "module x\n\ngo 1.26\n\nrequire (\n\tgithub.com/coder/websocket v1.8.14\n" +
		"\tgithub.com/spf13/pflag v1.0.10 // indirect\n)\n\nrequire example.com/single v2.0.0\n"
	got := parseGo(goMod)
	want := map[string]string{
		"github.com/coder/websocket": "v1.8.14",
		"github.com/spf13/pflag":     "v1.0.10",
		"example.com/single":         "v2.0.0",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseGo = %v, want %v", got, want)
	}
}

func TestParseNpm_RootLinkAndGitEntriesSkipped(t *testing.T) {
	got, err := parseNpm(npmLockFixture)
	if err != nil {
		t.Fatalf("parseNpm: %v", err)
	}
	want := map[string]string{
		"puppeteer-core": "25.2.0",
		"@scoped/pkg":    "1.0.0",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseNpm = %v, want %v", got, want)
	}
}

func TestParseNonregistry_SurfacesUnageableSources(t *testing.T) {
	t.Run("hex git and path entries", func(t *testing.T) {
		got := parseNonregistry("hex",
			`  "some_git": {:git, "https://x", "ref", []},
  "plug": {:hex, :plug, "1.0.0", "h", [:mix], [], "hexpm", "h"},
`)
		if len(got) != 1 || got["some_git"] == "" {
			t.Errorf("hex nonregistry = %v, want only some_git", got)
		}
	})

	t.Run("go single-line replace", func(t *testing.T) {
		got := parseNonregistry("go", "replace example.com/x => ./local\n")
		want := map[string]string{"example.com/x": "replace: ./local"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("go replace = %v, want %v", got, want)
		}
	})

	t.Run("go block replace", func(t *testing.T) {
		got := parseNonregistry("go", "replace (\n\texample.com/y => ../y v1.0.0\n)\n")
		want := map[string]string{"example.com/y": "replace: ../y v1.0.0"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("go block replace = %v, want %v", got, want)
		}
	})

	t.Run("npm link and git entries", func(t *testing.T) {
		got := parseNonregistry("npm", npmLockFixture)
		if len(got) != 2 || got["evil"] == "" || got["local"] != "non-registry: link" {
			t.Errorf("npm nonregistry = %v, want evil + local", got)
		}
	})
}

func TestBumpType(t *testing.T) {
	cases := []struct {
		old, new, want string
	}{
		{"", "1.0.0", "new"},
		{"1.2.3", "2.0.0", "major"},
		{"1.2.3", "1.3.0", "minor"},
		{"1.2.3", "1.2.4", "patch"},
		{"1.2", "1.3", "unknown"}, // not full semver -> conservative window
		{"v1.8.14", "v1.9.0", "minor"},
	}
	for _, c := range cases {
		t.Run(c.old+"->"+c.new, func(t *testing.T) {
			if got := bumpType(c.old, c.new); got != c.want {
				t.Errorf("bumpType(%q, %q) = %q, want %q", c.old, c.new, got, c.want)
			}
		})
	}
}

func TestGoEscape_UppercaseToBangLower(t *testing.T) {
	if got := goEscape("github.com/Azure/go-x"); got != "github.com/!azure/go-x" {
		t.Errorf("goEscape = %q", got)
	}
}

func TestEvaluate_RejectsTooFreshAndHonorsAllowlist(t *testing.T) {
	now := time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)
	daysAgo := func(d int) time.Time { return now.AddDate(0, 0, -d) }

	candidates := []candidate{
		{"hex", "fresh_patch", "1.2.3", "1.2.4"},         // 2d old, patch window 7 -> REJECT
		{"hex", "aged_patch", "1.2.3", "1.2.4"},          // 30d old, patch window 7 -> allow
		{"go", "github.com/x/major", "v1.0.0", "v2.0.0"}, // 20d old, major window 30 -> REJECT
		{"npm", "puppeteer-core", "25.2.0", "25.3.0"},    // 15d old, minor window 14 -> allow
	}
	ages := map[allowKey]time.Time{
		{"hex", "fresh_patch", "1.2.4"}:        daysAgo(2),
		{"hex", "aged_patch", "1.2.4"}:         daysAgo(30),
		{"go", "github.com/x/major", "v2.0.0"}: daysAgo(20),
		{"npm", "puppeteer-core", "25.3.0"}:    daysAgo(15),
	}

	got := evaluate(candidates, ages, map[allowKey]bool{}, now)
	rejected := map[string]bool{}
	for _, v := range got {
		rejected[v.pkg] = true
	}
	want := map[string]bool{"fresh_patch": true, "github.com/x/major": true}
	if !reflect.DeepEqual(rejected, want) {
		t.Errorf("rejected set = %v, want %v", rejected, want)
	}

	// The allowlist exempts the urgent fix.
	allowed := map[allowKey]bool{{"hex", "fresh_patch", "1.2.4"}: true}
	got = evaluate(candidates, ages, allowed, now)
	if len(got) != 1 || got[0].pkg != "github.com/x/major" {
		t.Errorf("allowlist did not exempt: %v", got)
	}
}

func TestLoadAllowlist_RequiresAReason(t *testing.T) {
	dir := t.TempDir()

	writeAllow := func(content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, allowlistPath), []byte(content), 0o600); err != nil {
			t.Fatalf("write allowlist: %v", err)
		}
	}

	writeAllow("# comment\nhex plug 1.18.0 GHSA-xxxx urgent fix\n")
	allowed, err := loadAllowlist(dir)
	if err != nil {
		t.Fatalf("loadAllowlist: %v", err)
	}
	if !allowed[allowKey{"hex", "plug", "1.18.0"}] {
		t.Errorf("entry not loaded: %v", allowed)
	}

	writeAllow("hex plug 1.18.0\n") // no reason
	if _, err := loadAllowlist(dir); err == nil {
		t.Error("a reason-less entry must be a hard error")
	}
}
