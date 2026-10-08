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
		fatal(fmt.Errorf("usage: go run ./tools/cmd/ci <select|install-mcp-publisher|normalize-mcp-private-key>"))
	}

	ctx := context.Background()
	switch os.Args[1] {
	case "verify-debian-sbom-decoder":
		if len(os.Args) != 2 {
			fatal(fmt.Errorf("usage: ci verify-debian-sbom-decoder"))
		}
		err = ci.VerifyDebianDecoder(ctx)
	case "image-contract":
		if len(os.Args) != 9 {
			fatal(fmt.Errorf("usage: ci image-contract create|verify PURPOSE REVISION IMAGE ARCHIVE SBOM CONTRACT"))
		}
		err = ci.ImageContract(ctx, root, os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6], os.Args[7], os.Args[8])
	case "diagnostics-sbom":
		if len(os.Args) != 6 {
			fatal(fmt.Errorf("usage: ci diagnostics-sbom REVISION IMAGE RUNTIME_SBOM DESTINATION"))
		}
		err = ci.DiagnosticsSBOM(ctx, root, os.Args[2], os.Args[3], os.Args[4], os.Args[5])
	case "diagnostics-scan":
		if len(os.Args) != 7 {
			fatal(fmt.Errorf("usage: ci diagnostics-scan REVISION IMAGE SBOM RAW_SCAN DECISIONS"))
		}
		err = ci.DiagnosticsScan(ctx, root, os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
	case "select":
		if len(os.Args) != 4 {
			fatal(fmt.Errorf("usage: ci select EVENT BASE"))
		}
		err = ci.WriteSelection(ctx, root, os.Args[2], os.Args[3], os.Getenv("GITHUB_OUTPUT"), os.Getenv("GITHUB_STEP_SUMMARY"))
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
