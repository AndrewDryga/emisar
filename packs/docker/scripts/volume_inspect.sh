#!/bin/bash
set -euo pipefail

name=$1

# Project the safe fields only. Options is the verbatim `docker volume create
# --opt` map — a CIFS/NFS local-driver volume's `o=` string carries mount
# credentials (username=,password=) — and Status is an open-ended
# driver-provided map; neither may reach model-visible output.
exec docker volume inspect --format \
  '{"Name":{{json .Name}},"Driver":{{json .Driver}},"Scope":{{json .Scope}},"CreatedAt":{{json .CreatedAt}},"Mountpoint":{{json .Mountpoint}},"Labels":{{json .Labels}}}' \
  "$name"
