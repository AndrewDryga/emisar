//go:build !darwin && !linux && !windows

package main

import "os"

func fileIsTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func fileTerminalSize(_ *os.File) (int, int, bool) {
	return 0, 0, false
}
