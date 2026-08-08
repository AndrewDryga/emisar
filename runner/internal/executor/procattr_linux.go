//go:build linux

package executor

import (
	"fmt"
	"os/exec"
	"os/user"
	"runtime"
	"strconv"
	"syscall"
)

// prSetNoNewPrivs is PR_SET_NO_NEW_PRIVS from linux/prctl.h. The value is the
// same on every architecture, but package syscall exports the constant on only
// some of them — arm64 has it, amd64 does not — so it is spelled out rather
// than referenced and silently failing to build the primary release target.
const prSetNoNewPrivs = 0x26

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

// startCommand forks the action from a thread carrying no_new_privs, so nothing
// the child execs — at any depth, for the life of the tree — can gain
// privileges from a setuid/setgid bit or from file capabilities. Without it,
// applyCredential's drop to an unprivileged user is not a boundary: the dropped
// child can exec any setuid binary on the host and climb straight back out of
// the credential it was confined to.
//
// no_new_privs is a per-THREAD attribute that children inherit across fork and
// keep across execve, so it has to be set on the exact thread that forks. That
// is what the lock buys: it pins this goroutine to its thread across Start,
// which would otherwise be free to fork from a thread that never got the
// prctl, leaving the protection silently absent.
//
// The thread is deliberately NOT retired afterwards. Pdeathsig is delivered
// when the FORKING THREAD exits, not when the process does
// (go.dev/issue/27505), so forking from a thread we then destroy would SIGKILL
// every action the moment it started. Unlocking hands an ordinary long-lived
// runtime thread back to the pool exactly as before this change; it simply
// carries no_new_privs from here on, which costs nothing — every exec this
// process makes is either an action that wants it or a systemctl/launchctl
// probe that does not care.
func startCommand(cmd *exec.Cmd) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if _, _, errno := syscall.RawSyscall6(
		syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0, 0, 0, 0,
	); errno != 0 {
		return fmt.Errorf("set no_new_privs: %w", errno)
	}
	return cmd.Start()
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
