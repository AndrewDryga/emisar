#!/bin/sh
# Stands in for the CLI via TF_BIN to hand `show -json` a document that still
# carries format_version but a scalar where resource_changes belongs — what a
# truncating proxy, a broken CLI wrapper, or a corrupted artifact can return.
# Reading it with []? would project a confident, entirely EMPTY summary for a
# plan whose contents are unknown; the projection must refuse instead.
cat <<'DOCUMENT'
{"format_version":"1.2","terraform_version":"1.15.8","resource_changes":7,"resource_drift":[],"output_changes":{}}
DOCUMENT
