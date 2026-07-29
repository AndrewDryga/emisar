#!/bin/sh
# Stands in for the CLI via TF_BIN to reproduce what a REMOTE-execution
# workspace does to `plan -json`. The preamble below is a real capture from an
# HCP Terraform workspace (execution mode "remote"), de-identified: the local
# CLI emits its own version message as JSON and then streams the remote run's
# HUMAN output, so the only parseable line is the version.
#
# This is the dangerous shape, which is why it exits 0 with changes present: a
# projection that merely skipped the unparseable lines would report a confident,
# entirely empty plan for a run that is about to change infrastructure.
cat <<'STREAM'
{"@level":"info","@message":"Terraform 1.15.8","@module":"terraform.ui","@timestamp":"2026-07-28T21:51:34.608466-06:00","terraform":"1.15.8","type":"version","ui":"1.3"}
Running plan in HCP Terraform. Output will stream here. Pressing Ctrl-C
will stop streaming the logs, but will not stop the plan running remotely.

Preparing the remote plan...

To view this run in a browser, visit:
https://app.terraform.io/app/example-org/example/runs/run-EXAMPLE000000000

Waiting for the plan to start...

Terraform v1.15.8
on linux_amd64
Initializing plugins and modules...

Terraform will perform the following actions:

  # google_compute_instance_template.portal must be replaced
+/- resource "google_compute_instance_template" "portal" {
    }

Plan: 1 to add, 3 to change, 1 to destroy.
STREAM
exit 0
