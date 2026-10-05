#!/usr/bin/env bash
# phobos host preparation on a VM-hosting node (hypervisor). Idempotent; run as root.
#  - NAT timeouts for dilated guests (idle UE / N2 mappings must not expire: D-28). The sysctl file alone does not
#    apply at boot (systemd-sysctl runs before nf_conntrack is loaded), so the module is loaded early as well.
set -euo pipefail
cat > /etc/sysctl.d/90-phobos-conntrack.conf <<'CONF'
# phobos/chronos: the VMs run in dilated virtual time, so an idle SCTP association (gNB N2, nFAPI P5) heartbeats
# only every 30 s *virtual* = up to hours real; the default expiry drops its NAT mapping for good.
net.netfilter.nf_conntrack_sctp_timeout_established = 432000
net.netfilter.nf_conntrack_udp_timeout_stream = 3600
CONF
echo nf_conntrack > /etc/modules-load.d/phobos-conntrack.conf
modprobe nf_conntrack
sysctl -q -p /etc/sysctl.d/90-phobos-conntrack.conf
echo "host_prep: conntrack udp_stream=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream) sctp=$(sysctl -n net.netfilter.nf_conntrack_sctp_timeout_established)"
