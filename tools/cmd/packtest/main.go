// Command packtest executes pack-owned behavioral plans inside the runner-tools container.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/andrewdryga/emisar/tools/internal/packtest"
)

type packNames []string

func (names *packNames) String() string { return fmt.Sprint([]string(*names)) }
func (names *packNames) Set(value string) error {
	*names = append(*names, value)
	return nil
}

func main() {
	config := packtest.Config{}
	var names packNames
	var list bool
	flag.StringVar(&config.Pattern, "pattern", "", "run pack names containing this value")
	flag.Var(&names, "pack", "run one exact pack name; repeat for more than one")
	flag.BoolVar(&list, "list", false, "print selected pack names as JSON without running them")
	flag.StringVar(&config.Emisar, "emisar", "", "path to the emisar runner binary")
	flag.StringVar(&config.PacksDir, "packs", "", "pack catalog root")
	flag.StringVar(&config.Config, "config", "", "runner test config")
	flag.StringVar(&config.Reports, "reports", "", "report output directory")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: packtest [--pattern name | --pack name ...]")
		os.Exit(2)
	}
	config.Names = names
	if list {
		plans, err := packtest.Discover(config.PacksDir, config.Pattern, config.Names...)
		if err != nil {
			fmt.Fprintln(os.Stderr, "packtest:", err)
			os.Exit(1)
		}
		selected := make([]string, 0, len(plans))
		for _, plan := range plans {
			selected = append(selected, plan.Name)
		}
		if err := json.NewEncoder(os.Stdout).Encode(selected); err != nil {
			fmt.Fprintln(os.Stderr, "packtest:", err)
			os.Exit(1)
		}
		return
	}
	if _, err := packtest.Run(config); err != nil {
		fmt.Fprintln(os.Stderr, "packtest:", err)
		os.Exit(1)
	}
}
