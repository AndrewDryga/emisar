package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStylerPaint(t *testing.T) {
	on := styler{enabled: true}
	off := styler{}

	if got := on.ok("✓"); got != "\x1b[32m✓\x1b[0m" {
		t.Errorf("enabled ok = %q", got)
	}
	if got := on.bold(""); got != "" {
		t.Errorf("empty text must stay empty, got %q", got)
	}
	if got := off.fail("✗"); got != "✗" {
		t.Errorf("disabled styler must pass text through, got %q", got)
	}
}

func TestStylerRiskLabel(t *testing.T) {
	style := styler{enabled: true}

	for _, tt := range []struct {
		tier string
		want string
	}{
		// Low stays neutral on purpose — green is the allow/brand color,
		// never a risk tier (portal parity).
		{"low", "3 low"},
		{"medium", "\x1b[33m3 medium\x1b[0m"},
		{"high", "\x1b[31m3 high\x1b[0m"},
		{"critical", "\x1b[1;31m3 critical\x1b[0m"},
	} {
		t.Run(tt.tier, func(t *testing.T) {
			if got := style.riskLabel("3 "+tt.tier, tt.tier); got != tt.want {
				t.Errorf("riskLabel(%s) = %q, want %q", tt.tier, got, tt.want)
			}
		})
	}
}

func TestNewStylerStaysPlainOffTerminals(t *testing.T) {
	t.Run("a non-file writer is plain", func(t *testing.T) {
		if newStyler(&bytes.Buffer{}).enabled {
			t.Error("bytes.Buffer must not get ANSI codes")
		}
	})

	t.Run("a regular file is plain", func(t *testing.T) {
		file, err := os.Create(filepath.Join(t.TempDir(), "out.txt"))
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		defer func() { _ = file.Close() }()

		if newStyler(file).enabled {
			t.Error("a redirected regular file must not get ANSI codes")
		}
	})

	t.Run("NO_COLOR wins even for files", func(t *testing.T) {
		t.Setenv("NO_COLOR", "")

		if newStyler(os.Stdout).enabled {
			t.Error("NO_COLOR must disable color everywhere")
		}
	})

	t.Run("TERM=dumb wins", func(t *testing.T) {
		t.Setenv("TERM", "dumb")

		if newStyler(os.Stdout).enabled {
			t.Error("TERM=dumb must disable color")
		}
	})
}

func TestReportDoctorPlainWithoutTerminal(t *testing.T) {
	var buf bytes.Buffer
	reportDoctor(&buf, []checkResult{{"config", checkOK, "loaded"}})

	if strings.Contains(buf.String(), "\x1b[") {
		t.Errorf("buffered doctor output must carry no ANSI codes:\n%q", buf.String())
	}
}
