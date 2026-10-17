#!/usr/bin/env bash
# phobos preparation inside a dilated worker VM (gNB / UE / core host). Idempotent; run with sudo.
set -euo pipefail
apt-get update -qq || true
apt-get install -yqq gdb lksctp-tools iperf3 >/dev/null || true
# SCTP for N2 (gNB <-> AMF), loaded at boot
echo sctp > /etc/modules-load.d/phobos-sctp.conf
modprobe sctp || true
# nFAPI P5 SCTP associations are multihomed (every alias advertised): dead alternate paths must not exhaust the
# association retransmission budget and abort a healthy primary path
echo 'net.sctp.association_max_retrans = 65535' > /etc/sysctl.d/90-phobos-sctp.conf
# gNB nFAPI P5/P7 ports (50601+8k / 50611+8k) sit inside the ephemeral range: hundreds of hostNetwork UE sockets
# on one VM can grab one first (gNB P7 bind EADDRINUSE)
echo 'net.ipv4.ip_local_reserved_ports = 50600-51600' > /etc/sysctl.d/91-phobos-ports.conf
# core dumps of crashing UEs/gNBs land in /var/crash (pods mount it): gdb post-mortems
mkdir -p /var/crash && chmod 1777 /var/crash
echo 'kernel.core_pattern=/var/crash/core.%e.%p.%t' > /etc/sysctl.d/92-phobos-core.conf
# a quiet console: framebuffer console printing under dilation caused soft lockups (D-4)
echo 'kernel.printk = 1 4 1 7' > /etc/sysctl.d/93-phobos-console-quiet.conf
# Receive packet steering: the virtio NIC has one RX queue, so every packet for the VM's hundreds of hostNetwork UEs
# (slot ticks, DL data) was processed on one vCPU; it fell behind, UEs got their ticks late, missed the slot round and
# the whole barrier waited for them (2026-10-11, 3x300: 42 -> 96 slots/s and dilation 32 -> 10.5 with RPS/RFS on)
echo 'net.core.rps_sock_flow_entries = 32768' > /etc/sysctl.d/94-phobos-rps.conf
cat > /usr/local/sbin/phobos-rps <<'EOF'
#!/bin/sh
# spread RX processing of every NIC queue over all CPUs (RPS) and steer flows to their consumer's CPU (RFS)
n=$(nproc); mask=$(python3 -c "s=format((1<<$n)-1,'x'); s=s.rjust((len(s)+7)//8*8,'0'); print(','.join(s[i:i+8] for i in range(0,len(s),8)))")
for q in /sys/class/net/*/queues/rx-*; do
  case "$q" in */lo/*) continue ;; esac
  echo "$mask" > "$q/rps_cpus"; echo 32768 > "$q/rps_flow_cnt"
done
EOF
chmod 755 /usr/local/sbin/phobos-rps
cat > /etc/systemd/system/phobos-rps.service <<'EOF'
[Unit]
Description=phobos: receive packet steering over all CPUs
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/phobos-rps
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now phobos-rps.service || true
sysctl -q --system || true
systemctl disable --now getty@tty1.service 2>/dev/null || true
G=/etc/default/grub.d/50-cloudimg-settings.cfg
if [ -f "$G" ] && ! grep -q nomodeset "$G"; then
  cp "$G" "$G.pre-phobos"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 nomodeset"/' "$G"
  update-grub >/dev/null 2>&1 || true            # takes effect at the next VM reboot
fi
echo 0 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
# where the phobos UE build (nr-uesoftmodem + libs + AWGN curves) is staged; UE pods mount it
mkdir -p /opt/phobos-ue && chown ubuntu:ubuntu /opt/phobos-ue
echo "vm_prep: done on $(hostname)"
