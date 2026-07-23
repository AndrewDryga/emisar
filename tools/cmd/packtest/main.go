// Command packtest executes generated action-pack cases inside the runner-tools container.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/andrewdryga/emisar/tools/internal/packtest"
)

func main() {
	config := packtest.Config{}
	flag.StringVar(&config.Pattern, "pattern", "", "run pack names containing this value")
	flag.StringVar(&config.Emisar, "emisar", "", "path to the emisar runner binary")
	flag.StringVar(&config.PacksDir, "packs", "", "pack catalog root")
	flag.StringVar(&config.Config, "config", "", "runner test config")
	flag.StringVar(&config.Reports, "reports", "", "report output directory")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: packtest [--pattern name]")
		os.Exit(2)
	}
	if _, err := packtest.Run(config); err != nil {
		fmt.Fprintln(os.Stderr, "packtest:", err)
		os.Exit(1)
	}
}
