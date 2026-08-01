//go:build linux

package browser

import "syscall"

// browserSysProcAttr gives the lifeline wrapper — and so the Chromium tree it leads — its own
// process group, because Chromium forks several children and cancellation kills the whole group.
// On Linux it also asks the kernel to kill the wrapper when this process dies.
//
// Pdeathsig is what covers the case the group kill cannot: that kill lives in the command's Cancel
// hook, which only runs on context cancellation. A coop box's watchdog SIGKILLs a wedged provider,
// and SIGKILL runs no Go cleanup, so without this the browser tree is orphaned onto the container's
// init — where it is nobody's child, outside the provider's process group, and holds the box open
// for the entire descendant drain. chromedp's own ExecAllocator sets this for the same reason;
// this launch bypasses chromedp, so it has to set it itself.
func browserSysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
}
