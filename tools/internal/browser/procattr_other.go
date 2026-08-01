//go:build !linux

package browser

import "syscall"

// Pdeathsig exists only on Linux, which is where boxes and CI run. A workstation keeps the process
// group so cancellation still takes Chromium's forked children with it.
func browserSysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}
