// dev-only load generator — deliberately its OWN module, NOT listed in the
// repo go.work, so it never ships and never joins the runner/mcp gates. Run its
// gate with GOWORK=off (see README) or Go refuses it as "not a workspace module".
module emisar.dev/loadtest

go 1.26.5
