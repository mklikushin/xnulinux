#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# hcmd.sh [TIMEOUT] < commands : run commands in the hosted macOS's console shell, output returned over the xnu0 link (not dmesg)
T=${1:-60}; cat > /var/tmp/www/cmd.sh
rm -f /var/tmp/hout; (timeout $T nc -l 192.168.77.1 8100 > /var/tmp/hout 2>/dev/null &)
sleep 0.5
printf '\ncurl -s -o /tmp/cmd.sh http://192.168.77.1:8099/cmd.sh; bash /tmp/cmd.sh 2>&1 | nc 192.168.77.1 8100\n' >> /var/tmp/console-in
while pgrep -f "nc -l 192.168.77.1 8100" >/dev/null; do sleep 1; done
cat /var/tmp/hout
