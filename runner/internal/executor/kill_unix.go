//go:build !linux && !windows

package executor

import "syscall"

// killGroup falls back to signalling the direct child only. Without Setpgid,
// signalling the negative pid would target an unrelated process group.
func killGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(pid, sig)
}
