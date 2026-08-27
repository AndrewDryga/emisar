//go:build linux

package main

import "syscall"

// termiosGetOp is the only byte that differs between the Unix terminal
// implementations: Darwin reads termios via TIOCGETA, Linux via TCGETS.
const termiosGetOp = uintptr(syscall.TCGETS)
