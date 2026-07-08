#!/bin/sh
# rip-proxy-start.sh — SNI destination router restart wrapper for rip-cage egress.
# Baked into the image at /usr/local/lib/rip-cage/rip-proxy-start.sh (root-owned, 755).
# Run as rip-proxy user via: su -s /bin/sh rip-proxy -c 'nohup ... &'
# NOT written to /tmp — /tmp is world-writable and replaceable by the agent user,
# which would allow agent code to run as rip-proxy (full firewall bypass).
#
# Pure destination router (rip-cage-ta1o.1):
#   Reads SNI from TLS ClientHello (in the clear) + SO_ORIGINAL_DST from
#   iptables REDIRECT, allow/denies the DESTINATION on still-sealed traffic,
#   forwards encrypted bytes unchanged. No TLS decryption, no CA, no per-host cert.
while true; do
  /opt/rip-cage-proxy/bin/python /usr/local/lib/rip-cage/rip_cage_router.py \
    2>>/var/log/rip-cage-proxy.log
  sleep 1
done
