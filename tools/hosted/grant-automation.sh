#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS, as root: let programs started over ssh capture the screen, send Apple events to other applications
# and drive the interface through the accessibility API, without the consent dialogs. A hosted system usually has no one at
# its screen: screencapture then fails ("could not create image from display") and osascript waits for good behind a dialog
# ("sshd-keygen-wrapper" wants access to control "Finder").
#
#   sudo sh grant-automation.sh                       ssh sessions; Finder, System Events, Terminal, Safari, Chrome
#   sudo CLIENTS="com.example.app /usr/local/bin/tool" TARGETS="com.apple.finder" sh grant-automation.sh
#   sudo REVOKE=1 sh grant-automation.sh              take the same rows out again
#
# CLIENTS: who is granted (a bundle identifier, or the path of a program that has none). A program started from an ssh
#   session is attributed to /usr/libexec/sshd-keygen-wrapper, the default.
# TARGETS: the applications CLIENTS may send Apple events to (bundle identifiers).
# USER_NAME: whose Apple-event grants (default: the console user).
#
# It writes rows into TCC's two databases: the system one (screen capture, accessibility, posting input events) and the
# user's (Apple events, one row per target). That needs the relaxed system integrity protection the hosted system boots
# with (lp-sip0); on a Mac with SIP on, the databases cannot be written. tccd is restarted to read them.
set -eu
[ "$(id -u)" = 0 ] || { echo "grant-automation: run as root (sudo)" >&2; exit 1; }
CLIENTS=${CLIENTS:-/usr/libexec/sshd-keygen-wrapper}
TARGETS=${TARGETS:-com.apple.finder com.apple.systemevents com.apple.Terminal com.apple.Safari com.google.Chrome}
USER_NAME=${USER_NAME:-$(stat -f %Su /dev/console)}
SYS="/Library/Application Support/com.apple.TCC/TCC.db"
# macOS 27 keeps the user's database in a container (/private/var/containers/Data/ProtectedSystem/<id>/...); before that
# it was in the home directory. It exists once the user has logged in.
USR=$(find /private/var/containers/Data/ProtectedSystem -name TCC.db -user "$USER_NAME" 2>/dev/null | head -1)
[ -n "$USR" ] || USR="/Users/$USER_NAME/Library/Application Support/com.apple.TCC/TCC.db"
[ -f "$SYS" ] || { echo "grant-automation: no $SYS" >&2; exit 1; }
[ -f "$USR" ] || { echo "grant-automation: no TCC database of $USER_NAME yet (log in once): Apple events not granted" >&2; USR=; }
row() {	# database, service, client, target or UNUSED
  case $3 in /*) t=1 ;; *) t=0 ;; esac
  if [ "${REVOKE:-0}" = 1 ]; then
    sqlite3 "$1" "delete from access where service='$2' and client='$3' and indirect_object_identifier='$4'"
  elif [ "$4" = UNUSED ]; then
    sqlite3 "$1" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags) values ('$2','$3',$t,2,4,1,'UNUSED',0)"
  else
    sqlite3 "$1" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,flags) values ('$2','$3',$t,2,3,1,0,'$4',0)"
  fi
}
for c in $CLIENTS; do
  for s in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent; do row "$SYS" $s "$c" UNUSED; done
  [ -z "$USR" ] || for g in $TARGETS; do row "$USR" kTCCServiceAppleEvents "$c" "$g"; done
done
killall tccd 2>/dev/null || true
[ "${REVOKE:-0}" = 1 ] && echo "grant-automation: revoked for: $CLIENTS" ||
  echo "grant-automation: screen capture, accessibility and input for: $CLIENTS; Apple events to: ${USR:+$TARGETS}"
