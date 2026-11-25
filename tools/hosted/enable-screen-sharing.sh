#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS, as root: turn on Screen Sharing, so the hosted desktop can be watched and driven from another
# machine (video of the screen, pointer and keyboard). The disk build's --screen-sharing on does the first half before the
# first boot; this does it on a running system and adds what a session needs to see and control the screen.
#
#   sudo sh enable-screen-sharing.sh          on
#   sudo OFF=1 sh enable-screen-sharing.sh    off again
#
# - launchd: com.apple.screensharing enabled and loaded (it listens on port 5900 inside the hosted system; nothing outside
#   the host can reach it unless you forward the port).
# - TCC: screen capture, input events and accessibility for com.apple.screensharing.agent in the system database. Without
#   them a client connects and is told "Screen Sharing is not permitted". This needs the relaxed system integrity
#   protection the hosted system boots with.
# Connect through an ssh tunnel, e.g. from a Mac:  ssh -N -L 5901:localhost:5900 USER@GUEST   then   open vnc://localhost:5901
# and log in as the hosted user. The server offers only Apple's authentication types: use macOS's Screen Sharing, or
# tools/cloud/vnc-check.py for a check without a window.
set -eu
[ "$(id -u)" = 0 ] || { echo "enable-screen-sharing: run as root (sudo)" >&2; exit 1; }
DB="/Library/Application Support/com.apple.TCC/TCC.db"; C=com.apple.screensharing.agent
if [ "${OFF:-0}" = 1 ]; then
  launchctl bootout system/com.apple.screensharing 2>/dev/null || true
  launchctl disable system/com.apple.screensharing
  sqlite3 "$DB" "delete from access where client='$C'"; killall tccd 2>/dev/null || true
  echo "enable-screen-sharing: off"; exit 0
fi
launchctl enable system/com.apple.screensharing
launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
for s in kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceAccessibility; do
  sqlite3 "$DB" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags) values ('$s','$C',0,2,4,1,'UNUSED',0)"
done
killall tccd 2>/dev/null || true
nc -z -G 3 127.0.0.1 5900 >/dev/null 2>&1 && echo "enable-screen-sharing: listening on port 5900" || { echo "enable-screen-sharing: port 5900 does not answer" >&2; exit 1; }
