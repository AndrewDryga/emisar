//go:build linux

package executor

import (
	"fmt"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"
)

// applyProcAttr sets process attributes that protect against orphaned
// children. On Linux:
//
//   - Pdeathsig: SIGKILL — kernel signals the direct child when the runner
//     process dies (for ANY reason, including SIGKILL/OOM/panic). This is
//     the only mechanism that survives a hard kill of the parent.
//   - Setpgid: true — child runs in its own process group whose pgid
//     equals the child's pid. We use this on cancellation to deliver the
//     signal to the entire tree (kill(-pgid, ...)), which catches
//     grandchildren spawned via bash/sh script actions.
//
// Caveat: Pdeathsig only signals the direct child. A bash wrapper that
// forks `nodetool` and exits would still orphan nodetool to init. Pack
// authors writing wrapper scripts should `exec` the target binary or
// `trap` and forward signals.
func applyProcAttr(cmd *exec.Cmd) {
	attr := cmd.SysProcAttr
	if attr == nil {
		attr = &syscall.SysProcAttr{}
	}
	attr.Pdeathsig = syscall.SIGKILL
	attr.Setpgid = true
	cmd.SysProcAttr = attr
}

// killGroup sends sig to the child's whole process group. Used by the
// cancellation path so SIGTERM reaches every descendant.
func killGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(-pid, sig)
}

// applyCredential drops the child to the given username's uid/gid
// before exec. The runner must itself be privileged (typically root)
// for this to succeed; an unprivileged runner calling setuid(other)
// produces EPERM at exec time. Pack authors use this so an action
// targeting Cassandra can run as the `cassandra` user even when the
// runner ships under a service user with elevated rights.
//
// The username may be either a name ("cassandra") or a numeric uid
// ("999"). Both forms are resolved via os/user. Group is set to the
// user's primary GID. Supplementary groups are NOT loaded (keeping
// the dropped child to the minimum set declared on the user record).
func applyCredential(cmd *exec.Cmd, username string) error {
	u, err := lookupUser(username)
	if err != nil {
		return err
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return fmt.Errorf("parse uid %q: %w", u.Uid, err)
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return fmt.Errorf("parse gid %q: %w", u.Gid, err)
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Credential = &syscall.Credential{
		Uid:         uint32(uid),
		Gid:         uint32(gid),
		Groups:      nil,
		NoSetGroups: false,
	}
	return nil
}

func lookupUser(s string) (*user.User, error) {
	if _, err := strconv.Atoi(s); err == nil {
		return user.LookupId(s)
	}
	return user.Lookup(s)
}
