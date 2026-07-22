# FRR + AgentX + snmpd SUT for the emisar `snmp` pack's ROUTING reads
# (snmp.bgp_peers / snmp.ospf_general / snmp.ospf_neighbors).
#
# The plain `snmpd` SUT (../snmpd) answers the system/interface OIDs but returns
# "No Such Object" for BGP4-MIB (1.3.6.1.2.1.15) and OSPF-MIB (1.3.6.1.2.1.14) —
# net-snmp doesn't serve those. FRR does, via AgentX: bgpd/ospfd load their
# `-M snmp` module, connect to snmpd's AgentX master socket, and register the
# BGP4-MIB / OSPF-MIB subtrees. snmpd then proxies walks of those OIDs to FRR.
#
# The official frrouting/frr image ships NO snmp module (and is amd64-only), so
# build from Debian 13 (same base as ../snmpd + the Debian fleet): its `frr-snmp`
# package ships bgpd_snmp.so / ospfd_snmp.so / zebra_snmp.so natively for arm64.
# Read-only, v2c community "public" — matching the plain snmpd SUT's contract.
FROM debian:13-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends frr frr-snmp snmpd snmp \
    && rm -rf /var/lib/apt/lists/*

# FRR config baked in (vtysh writes integrated config, so frr.conf is canonical):
#   daemons   — enable bgpd/ospfd, add `-M snmp` to zebra/bgpd/ospfd
#   frr.conf  — `agentx` + a BGP neighbor + OSPF on a dummy iface (produces rows)
COPY daemons   /etc/frr/daemons
COPY frr.conf  /etc/frr/frr.conf
COPY snmpd.conf /etc/snmp/snmpd.conf
COPY entrypoint.sh /entrypoint.sh
RUN chown frr:frr /etc/frr/daemons /etc/frr/frr.conf \
    && chmod 640 /etc/frr/daemons /etc/frr/frr.conf \
    && chmod 755 /entrypoint.sh

EXPOSE 161/udp
# Start snmpd (AgentX master) first, then FRR (so bgpd/ospfd can connect to the
# AgentX socket and register their MIBs). entrypoint.sh stays in the foreground.
ENTRYPOINT ["/entrypoint.sh"]
