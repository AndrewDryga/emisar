//go:build darwin || linux

package main

import (
	"os"
	"syscall"
	"unsafe"
)

func fileIsTerminal(file *os.File) bool {
	var termios syscall.Termios
	_, _, errno := syscall.Syscall6(
		syscall.SYS_IOCTL,
		file.Fd(),
		termiosGetOp,
		uintptr(unsafe.Pointer(&termios)),
		0,
		0,
		0,
	)
	return errno == 0
}

func fileTerminalSize(file *os.File) (int, int, bool) {
	var size struct {
		rows, columns, width, height uint16
	}
	_, _, errno := syscall.Syscall6(
		syscall.SYS_IOCTL,
		file.Fd(),
		uintptr(syscall.TIOCGWINSZ),
		uintptr(unsafe.Pointer(&size)),
		0,
		0,
		0,
	)
	valid := errno == 0 && size.columns > 0 && size.rows > 0
	return int(size.columns), int(size.rows), valid
}
