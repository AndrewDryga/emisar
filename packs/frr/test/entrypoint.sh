#!/bin/sh
# The daemons the pack reads and mutates, plus the dummy link they run on.
# Needs NET_ADMIN (compose cap_add) to create it.
set -eu

ip link add dum0 type dummy 2>/dev/null || true
ip addr add 10.0.0.1/24 dev dum0 2>/dev/null || true
ip link set dum0 up

mkdir -p /run/frr && chown frr:frr /run/frr
/usr/lib/frr/frrinit.sh start

# The VTY sockets are group-frrvty; the runner joins this /run/frr as another
# container, so the directory has to be traversable by that group there too.
chmod 0750 /run/frr

# Stay in the foreground as PID 1. watchfrr supervises the daemons; -F retries
# until zebra creates the log.
i=0
while [ ! -f /var/log/frr/frr.log ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.1
done
exec tail -F /var/log/frr/frr.log /dev/null
