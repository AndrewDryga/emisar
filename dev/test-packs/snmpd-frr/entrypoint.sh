#!/bin/sh
# Boot order matters: snmpd (the AgentX MASTER) must be up first so FRR's
# bgpd/ospfd subagents can connect to /var/agentx/master and register their MIBs.
# Then the main FRR, then a second tiny FRR (zebra+ospfd) in a peer netns so a REAL
# OSPF adjacency forms (→ ospfNbrTable has a row). Needs NET_ADMIN (compose cap_add).
set -eu

# --- network plumbing (kernel links FRR will run protocols on) -----------------
# dum0 carries the OSPF area-0 router-id + an address; dum1 a second advertised
# subnet. veth-main <-> veth-peer(ns1) is the link the OSPF adjacency forms over.
ip link add dum0 type dummy 2>/dev/null || true
ip link add dum1 type dummy 2>/dev/null || true
ip addr add 10.0.0.1/24 dev dum0 2>/dev/null || true
ip addr add 10.0.1.1/24 dev dum1 2>/dev/null || true
ip link set dum0 up
ip link set dum1 up

ip netns add ns1 2>/dev/null || true
ip link add veth-main type veth peer name veth-peer 2>/dev/null || true
ip link set veth-peer netns ns1
ip addr add 192.168.99.1/30 dev veth-main 2>/dev/null || true
ip link set veth-main up
ip netns exec ns1 ip addr add 192.168.99.2/30 dev veth-peer 2>/dev/null || true
ip netns exec ns1 ip link set veth-peer up
ip netns exec ns1 ip link set lo up

# --- 1) snmpd as AgentX master --------------------------------------------------
mkdir -p /var/agentx
mkdir -p /run/frr && chown frr:frr /run/frr
# MIBS= silences the harmless "Cannot adopt OID" MIB-parse warnings (the SUT is
# numeric-by-design and ships no working MIB tree). -Lo logs to stdout, -C uses
# only our config file.
MIBS= /usr/sbin/snmpd -Lo -C -c /etc/snmp/snmpd.conf
# Wait for the AgentX socket so FRR's subagents have something to connect to.
i=0
while [ ! -S /var/agentx/master ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.1
done

# --- 2) main FRR (zebra + bgpd + ospfd, each -M snmp) ---------------------------
# frrinit.sh reads /etc/frr/daemons + loads /etc/frr/frr.conf; watchfrr supervises.
/usr/lib/frr/frrinit.sh start
# Give the subagents a moment to connect + register their MIBs with snmpd.
sleep 3

# --- 3) second FRR in ns1 so an OSPF adjacency forms ---------------------------
# A standalone zebra+ospfd inside the peer netns, separate run/config dirs + vty
# sockets. point-to-point + matched timers bring the adjacency to Full (state 8).
mkdir -p /run/frr2 && chown frr:frr /run/frr2
mkdir -p /etc/frr2
cat >/etc/frr2/zebra.conf <<'EOF'
hostname peer-zebra
EOF
cat >/etc/frr2/ospfd.conf <<'EOF'
hostname peer-ospfd
interface veth-peer
 ip ospf network point-to-point
 ip ospf hello-interval 1
 ip ospf dead-interval 4
!
router ospf
 ospf router-id 192.168.99.2
 network 192.168.99.0/30 area 0
EOF
chown frr:frr /etc/frr2/zebra.conf /etc/frr2/ospfd.conf
ip netns exec ns1 /usr/lib/frr/zebra -d -i /run/frr2/zebra.pid -z /run/frr2/zserv.api -f /etc/frr2/zebra.conf --vty_socket /run/frr2
sleep 1
ip netns exec ns1 /usr/lib/frr/ospfd -d -i /run/frr2/ospfd.pid -z /run/frr2/zserv.api -f /etc/frr2/ospfd.conf --vty_socket /run/frr2

# --- stay in the foreground (PID 1) --------------------------------------------
# watchfrr keeps the main daemons up; tail FRR's log (zebra writes it on start) so
# the container doesn't exit. -F retries if the file isn't there yet.
i=0
while [ ! -f /var/log/frr/frr.log ] && [ "$i" -lt 50 ]; do
	i=$((i + 1))
	sleep 0.1
done
exec tail -F /var/log/frr/frr.log /dev/null
