#!/bin/sh
# Stands in for the CLI via TF_BIN to hand `show -json` a document from a
# format major no released CLI emits. The JSON-format contract says a consumer
# must reject an unsupported major: a 2.x document could keep these collection
# types while changing what the members mean, so projecting it would report a
# truthful-looking summary of a plan whose semantics are unknown.
cat <<'DOCUMENT'
{"format_version":"2.0","terraform_version":"3.0.0","resource_changes":[],"resource_drift":[],"output_changes":{}}
DOCUMENT
