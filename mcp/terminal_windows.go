//go:build windows

package main

import (
	"os"
	"syscall"
)

func fileIsTerminal(file *os.File) bool {
	var mode uint32
	return syscall.GetConsoleMode(syscall.Handle(file.Fd()), &mode) == nil
}

func fileTerminalSize(_ *os.File) (int, int, bool) {
	return 0, 0, false
}
