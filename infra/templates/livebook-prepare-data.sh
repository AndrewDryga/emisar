#!/bin/bash
set -euo pipefail

device=/dev/disk/by-id/google-livebook-data
mountpoint=/mnt/disks/emisar-livebook

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

install -d -m 0750 "$mountpoint"
if ! mountpoint -q "$mountpoint"; then
  mount -o rw,nosuid,nodev "$device" "$mountpoint"
fi

chown 1000:1000 "$mountpoint"
chmod 0750 "$mountpoint"
