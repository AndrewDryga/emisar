// Command installtest exercises the public runner and MCP shell installers.
package main

import (
	"fmt"
	"os"

	"github.com/andrewdryga/emisar/tools/internal/installtest"
	"github.com/andrewdryga/emisar/tools/internal/repo"
)

func main() {
	if len(os.Args) != 2 || os.Args[1] != "runner" && os.Args[1] != "mcp" {
		fmt.Fprintln(os.Stderr, "usage: installtest runner|mcp")
		os.Exit(2)
	}

	root, err := repo.Root()
	if err != nil {
		fmt.Fprintln(os.Stderr, "installtest:", err)
		os.Exit(1)
	}

	switch os.Args[1] {
	case "runner":
		err = installtest.Runner(root, os.Stdout)
	case "mcp":
		err = installtest.MCP(root, os.Stdout)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "installtest:", err)
		os.Exit(1)
	}
}
