//go:build !windows

package browser

import (
	"bufio"
	"context"
	"fmt"
	"github.com/chromedp/chromedp"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLifelinePreservesExistingDescriptors(t *testing.T) {
	keep, child, err := newLifeline()
	if err != nil {
		t.Fatal(err)
	}
	defer keep.Close()
	defer child.Close()
	inputPath := filepath.Join(t.TempDir(), "input")
	if err := os.WriteFile(inputPath, []byte("protocol remains intact\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	input, err := os.Open(inputPath)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	output, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	defer writer.Close()
	cmd := exec.Command("/bin/sh", "-c", `IFS= read -r value <&3; printf '%s\n' "$value" >&4; sleep 60`)
	cmd.ExtraFiles = []*os.File{input, writer}
	wrapWithLifeline(cmd, child)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	_ = child.Close()
	_ = writer.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	received := make(chan string, 1)
	go func() {
		value, err := bufio.NewReader(output).ReadString('\n')
		if err != nil {
			received <- fmt.Sprintf("read failed: %v", err)
			return
		}
		received <- value
	}()
	select {
	case value := <-received:
		if value != "protocol remains intact\n" {
			t.Fatalf("inherited descriptors: %q", value)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("child did not use its inherited descriptors")
	}
	select {
	case err := <-done:
		t.Fatalf("wrapper exited while its lifeline was held: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	_ = keep.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("wrapper should be killed after owner closes lifeline")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("wrapper survived closed lifeline")
	}
}

func TestIsolatedSessionBoundsUnresponsiveStartup(t *testing.T) {
	fakeChrome := filepath.Join(t.TempDir(), "chrome")
	if err := os.WriteFile(fakeChrome, []byte("#!/bin/sh\nexec sleep 60\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CHROME", fakeChrome)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started := time.Now()
	session, err := New(Config{}).isolatedSessionWithOptions(ctx, "", chromedp.WSURLReadTimeout(75*time.Millisecond))
	if session != nil {
		session.Close()
		t.Fatal("unresponsive Chrome produced a session")
	}
	if err == nil || !strings.Contains(err.Error(), "websocket url timeout") {
		t.Fatalf("startup error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("startup timeout took %v", elapsed)
	}
}
