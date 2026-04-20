#!/bin/sh
# rip-proxy-start.sh — mitmproxy restart wrapper for rip-cage egress firewall.
# Baked into the image at /usr/local/lib/rip-cage/rip-proxy-start.sh (root-owned, 755).
# Run as rip-proxy user via: su -s /bin/sh rip-proxy -c 'nohup ... &'
# NOT written to /tmp — /tmp is world-writable and replaceable by the agent user,
# which would allow agent code to run as rip-proxy (full firewall bypass).
while true; do
  mitmdump --mode transparent --listen-host 127.0.0.1 --listen-port 8080 \
    --set confdir=/etc/rip-cage/mitmproxy \
    -s /usr/local/lib/rip-cage/rip_cage_egress.py \
    2>>/var/log/rip-cage-proxy.log
  sleep 1
done
