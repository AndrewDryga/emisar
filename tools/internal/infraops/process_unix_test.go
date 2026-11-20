//go:build !windows

package infraops

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The terminal delivers Ctrl-C to its foreground process group. A tunnel child
// leads a group of its own, so the interrupt meant for psql never reaches it,
// and stopping it kills what it started as well.
func TestTunnelChildLeavesTheTerminalGroupAndStopsWithItsChildren(t *testing.T) {
	command := exec.CommandContext(t.Context(), "sh", "-c", `sleep 60 & echo $!; wait`)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	process, err := startBackground(command)
	if err != nil {
		t.Fatal(err)
	}
	defer process.stop()

	pid := command.Process.Pid
	group, err := syscall.Getpgid(pid)
	if err != nil {
		t.Fatal(err)
	}
	if group != pid || group == syscall.Getpgrp() {
		t.Fatalf("tunnel child group = %d, want its own (%d), not ours (%d)", group, pid, syscall.Getpgrp())
	}

	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	helper, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}
	process.stop()
	<-process.done
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		if err := syscall.Kill(helper, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("helper %d outlived the stopped tunnel", helper)
		}
	}
}

// The devtool's context ends on Ctrl-C. The interactive session must not: psql
// handles that interrupt itself. TERM and HUP still end it.
func TestInteractiveSessionOutlivesInterruptButNotHangup(t *testing.T) {
	// The devtool's own registration, so the signals below reach handlers
	// instead of ending the test binary.
	parent, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	session, stopSession := interactiveSession(parent)
	defer stopSession()

	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	select {
	case <-parent.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("SIGINT did not end the devtool context")
	}
	select {
	case <-session.Done():
		t.Fatal("SIGINT ended the interactive session")
	case <-time.After(200 * time.Millisecond):
	}

	if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	select {
	case <-session.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("SIGHUP did not end the interactive session")
	}
}
