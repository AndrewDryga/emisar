#!/bin/bash
set -euo pipefail

device=/dev/disk/by-id/google-livebook-data
mountpoint=/mnt/disks/emisar-livebook
notebook_source=/var/lib/emisar-livebook/notebooks
notebook_target="$mountpoint/notebooks/Emisar Product Analytics"

for _attempt in $(seq 1 60); do
  [ -b "$device" ] && break
  sleep 1
done
[ -b "$device" ] || { echo "Livebook data disk did not appear" >&2; exit 1; }

filesystem=$(/sbin/blkid -s TYPE -o value "$device" || true)
case "$filesystem" in
  "")
    /sbin/mkfs.ext4 -F -m 0 -L emisar-livebook "$device"
    ;;
  ext4) ;;
  *)
    echo "Refusing to mount unexpected Livebook data filesystem: $filesystem" >&2
    exit 1
    ;;
esac

# noexec: this is the one writable persistent path a notebook reaches, and the
# container's tmpfs layout already denies execution everywhere except the home
# tmpfs Mix.install needs. Without it a notebook could drop a binary here and
# run it, which is the exact escape the rest of the layout is built to prevent.
# Notebooks persist sources and outputs on this disk, never executables.
# A remount converges a VM whose disk was already mounted without the option.
install -d -m 0750 "$mountpoint"
if mountpoint -q "$mountpoint"; then
  mount -o remount,rw,nosuid,nodev,noexec "$mountpoint"
else
  mount -o rw,nosuid,nodev,noexec "$device" "$mountpoint"
fi

chown 1000:1000 "$mountpoint"
chmod 0750 "$mountpoint"
install -d -o 1000 -g 1000 -m 0750 "$mountpoint/.livebook"
install -d -o 1000 -g 1000 -m 0750 "$mountpoint/notebooks"
install -d -o 1000 -g 1000 -m 0750 "$notebook_target"

# Canonical dashboards recover from Git, while operator edits on the persistent
# disk win. A reboot or replacement seeds only files that are not already there.
#
# The seeded copies keep their repository filenames, which is why none of them
# may carry `persist_outputs: true`. These notebooks select per-account rows —
# account names, MRR, runner identities — so persisting output writes real
# customer data onto this prevent_destroy disk on every run, where it survives
# livebook_running = false and is not touched by emisar.admin.account.erase; and
# a copy of an edited dashboard back into Git lands on exactly this path, in a
# PUBLIC repository. Livebook's default is false, so leaving the annotation out
# is the whole control. Re-run the dashboard instead — it takes seconds.
for source in "$notebook_source"/*.livemd; do
  [ -e "$source" ] || continue
  destination="$notebook_target/$(basename "$source")"

  if [ ! -e "$destination" ]; then
    install -o 1000 -g 1000 -m 0640 "$source" "$destination"
  fi
done
