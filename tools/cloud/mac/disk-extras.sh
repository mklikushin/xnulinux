#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# disk-extras.sh: remote access for the hosted macOS, written into the disk image while it is being made. NOT run by
# hand: build-disk.sh (EXTRAS=1) sources it from inside scripts/mk-macvm-disk.sh while the image's Data volume is
# mounted at $D. Uses sudo -n like that script.
#   1. Remote Login (sshd) and Screen Sharing enabled in launchd's override list
#   2. GUEST_PUBKEY_FILE (your ssh public key) as the user xnu's authorized_keys
# Status: only syntax-checked in this cleaned form; the private original (which also copied an application from the
# Mac; use APPS for that now) made the image used throughout.
sudo -n D="$D" python3 - <<'PY'
import os, plistlib
p = os.environ["D"] + "/private/var/db/com.apple.xpc.launchd/disabled.plist"
d = plistlib.load(open(p, "rb")) if os.path.exists(p) else {}
d.update({"com.openssh.sshd": False, "com.apple.screensharing": False})   # False = not disabled
plistlib.dump(d, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
print("extras: sshd and screensharing enabled in launchd's override list")
PY
# the user xnu is uid 501, gid 20
if [ -s "${GUEST_PUBKEY_FILE:-}" ] && sudo -n test -d "$D/Users/xnu"; then
  sudo -n mkdir -p "$D/Users/xnu/.ssh"; sudo -n cp "$GUEST_PUBKEY_FILE" "$D/Users/xnu/.ssh/authorized_keys"
  sudo -n chown -R 501:20 "$D/Users/xnu/.ssh"; sudo -n chmod 700 "$D/Users/xnu/.ssh"; sudo -n chmod 600 "$D/Users/xnu/.ssh/authorized_keys"
  echo "extras: authorized_keys for xnu"
else
  echo "extras: no ssh key installed (GUEST_PUBKEY_FILE unset or empty, or no /Users/xnu on the Data volume: $(sudo -n ls "$D/Users" | tr '\n' ' '))"
fi
