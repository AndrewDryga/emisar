//go:build windows

package installtest

import (
	"fmt"
	"io"
)

func MCP(string, io.Writer) error {
	return fmt.Errorf("the shell MCP installer tests require Unix")
}

func Runner(string, io.Writer) error {
	return fmt.Errorf("the runner installer tests require Unix")
}
