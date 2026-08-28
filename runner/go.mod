module github.com/andrewdryga/emisar/runner

go 1.26.6

require (
	github.com/coder/websocket v1.8.15
	github.com/santhosh-tekuri/jsonschema/v6 v6.0.2
	github.com/spf13/cobra v1.10.2
	// Direct only because the CLI-surface golden test walks flags through
	// pflag.Flag, which is cobra's own flag type — there is no other way to
	// read a command's shorthands and types. Zero supply-chain delta: cobra
	// requires it regardless. Called out because runner/AGENTS.md asks every
	// direct requirement in this client-shipped module to justify itself, and
	// this one otherwise reads as production-load-bearing.
	github.com/spf13/pflag v1.0.10
	go.yaml.in/yaml/v3 v3.0.4
)

require (
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	golang.org/x/text v0.40.0 // indirect
)
