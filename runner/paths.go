package main

import (
	"fmt"
	"io"
	"strings"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
)

// writePaths appends the resolved filesystem locations to the root help —
// where the config, packs, token, and logs live is the first thing an
// operator hunts for on a new host. Fail-soft: with no config the section
// still prints the search locations, so a fresh host learns where to put one.
func writePaths(w io.Writer) {
	fmt.Fprintf(w, "\nPaths:\n")

	path, err := resolveConfigPath()
	if err != nil {
		writePathLine(w, "config", "not found — looked in $EMISAR_CONFIG, "+strings.Join(defaultConfigPaths(), ", "))
		return
	}

	cfg, err := config.Load(path)
	if err != nil {
		writePathLine(w, "config", fmt.Sprintf("%s (failed to load: %s)", path, err))
		return
	}

	packDirs := cfg.Paths.Packs
	if len(flagPacksDir) > 0 {
		packDirs = flagPacksDir
	}

	writePathLine(w, "config", path)
	writePathLine(w, "packs", strings.Join(packDirs, ", "))
	writePathLine(w, "data dir", cfg.Paths.DataDir)
	writePathLine(w, "token", cfg.Cloud.TokenPath)
	writePathLine(w, "dispatch log", cloud.DispatchLogPath(cfg.Paths.DataDir))
	writePathLine(w, "events journal", cfg.Events.JSONLPath)
}

func writePathLine(w io.Writer, name, value string) {
	if value == "" {
		value = "—"
	}
	fmt.Fprintf(w, "  %-14s  %s\n", name, value)
}
