// Command ci implements repository-specific CI policy without shell helpers.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/andrewdryga/emisar/tools/internal/ci"
	"github.com/andrewdryga/emisar/tools/internal/repo"
)

func main() {
	root, err := repo.Root()
	if err != nil {
		fatal(err)
	}
	if len(os.Args) < 2 {
		fatal(fmt.Errorf("usage: go run ./tools/cmd/ci <select|frozen-migrations|install-mcp-publisher|normalize-mcp-private-key>"))
	}

	ctx := context.Background()
	switch os.Args[1] {
	case "select":
		if len(os.Args) != 4 {
			fatal(fmt.Errorf("usage: ci select EVENT BASE"))
		}
		err = ci.WriteSelection(ctx, root, os.Args[2], os.Args[3], os.Getenv("GITHUB_OUTPUT"), os.Getenv("GITHUB_STEP_SUMMARY"))
	case "frozen-migrations":
		if len(os.Args) != 4 {
			fatal(fmt.Errorf("usage: ci frozen-migrations EVENT BASE"))
		}
		err = ci.CheckFrozenMigrations(ctx, root, os.Args[2], os.Args[3])
	case "install-mcp-publisher":
		if len(os.Args) > 3 {
			fatal(fmt.Errorf("usage: ci install-mcp-publisher [destination]"))
		}
		destination := "./mcp-publisher"
		if len(os.Args) == 3 {
			destination = os.Args[2]
		}
		err = ci.InstallMCPPublisher(ctx, destination)
	case "normalize-mcp-private-key":
		if len(os.Args) != 2 {
			fatal(fmt.Errorf("usage: ci normalize-mcp-private-key"))
		}
		var seed string
		seed, err = ci.NormalizeEd25519Seed(os.Getenv("MCP_PRIVATE_KEY"))
		if err == nil {
			fmt.Println(seed)
		}
	default:
		fatal(fmt.Errorf("unknown CI command %q", os.Args[1]))
	}
	if err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "::error::%v\n", err)
	os.Exit(1)
}
