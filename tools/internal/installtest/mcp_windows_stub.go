//go:build !windows

package installtest

import (
	"fmt"
	"io"
)

func MCPWindows(string, io.Writer) error {
	return fmt.Errorf("mcp-windows installer tests require Windows")
}
