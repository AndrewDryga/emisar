package main

import (
	"io"
	"os"
)

// styler colors human-facing CLI output when the terminal supports it —
// plain bytes otherwise, so pipes, files, tests, and --json consumers never
// see escape codes. Disabled unless the writer is a real character device,
// and always disabled under NO_COLOR (https://no-color.org) or TERM=dumb.
type styler struct{ enabled bool }

// newStyler decides once per command whether w gets ANSI color.
func newStyler(w io.Writer) styler {
	file, ok := w.(*os.File)
	if !ok {
		return styler{}
	}
	if _, set := os.LookupEnv("NO_COLOR"); set {
		return styler{}
	}
	if os.Getenv("TERM") == "dumb" {
		return styler{}
	}
	info, err := file.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return styler{}
	}
	return styler{enabled: true}
}

func (s styler) paint(code, text string) string {
	if !s.enabled || text == "" {
		return text
	}
	return "\x1b[" + code + "m" + text + "\x1b[0m"
}

// The semantic faces, matching the portal's status palette: pass = green,
// caution = yellow, danger = red. Labels bold; secondary facts dim.
func (s styler) ok(text string) string   { return s.paint("32", text) }
func (s styler) warn(text string) string { return s.paint("33", text) }
func (s styler) fail(text string) string { return s.paint("31", text) }
func (s styler) bold(text string) string { return s.paint("1", text) }
func (s styler) dim(text string) string  { return s.paint("2", text) }

// riskLabel colors one "N tier" pair the way the portal's risk pills do:
// low stays NEUTRAL (green is the brand/allow color, deliberately never a
// risk tier), medium = yellow, high = red, critical = bold red.
func (s styler) riskLabel(text, tier string) string {
	switch tier {
	case "medium":
		return s.warn(text)
	case "high":
		return s.fail(text)
	case "critical":
		return s.paint("1;31", text)
	default:
		return text
	}
}
