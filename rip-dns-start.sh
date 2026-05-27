#!/bin/sh
# rip-dns-start.sh — DNS resolver sidecar restart wrapper for rip-cage.
# Baked into the image at /usr/local/lib/rip-cage/rip-dns-start.sh (root-owned, 755).
# Run as rip-proxy user via: su -s /bin/sh rip-proxy -c 'nohup ... &'
# NOT written to /tmp — /tmp is world-writable and replaceable by the agent user,
# which would allow agent code to run as rip-proxy (full firewall bypass).
while true; do
  /opt/rip-cage-proxy/bin/python /usr/local/lib/rip-cage/rip_cage_dns.py \
    2>>/var/log/rip-cage-dns.log
  sleep 1
done
