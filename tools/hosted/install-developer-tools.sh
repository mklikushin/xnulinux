#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS, as root: install Apple's Command Line Tools (clang, git, make, python3, the macOS SDK) from
# Apple's software update server. A disk built on Linux has no developer tools (docs/cloud-arm.md section 7), and
# /usr/bin/git and /usr/bin/python3 are stubs that ask for them in a dialog on the hosted screen.
#
#   sudo sh install-developer-tools.sh
#
# About 520 MB to download, 2.5 GB installed; two to three minutes on a cloud VM. Does nothing when the tools are
# there. The tuning of docs/cloud-arm.md section 12 disables softwareupdated: it is enabled for the install and
# disabled again afterwards. Nothing else is installed: no system update is asked for.
# Exit: 0 the tools are installed and clang and git run, 1 otherwise.
set -eu
[ "$(id -u)" = 0 ] || { echo "install-developer-tools: run as root (sudo)" >&2; exit 1; }
have() { d=$(xcode-select -p 2>/dev/null) && [ -x "$d/usr/bin/clang" ] && [ -x "$d/usr/bin/git" ]; }
if have; then echo "install-developer-tools: already installed: $(xcode-select -p)"; exit 0; fi
off=0
if launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.softwareupdated" => disabled'; then
  off=1; launchctl enable system/com.apple.softwareupdated
  launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.softwareupdated.plist 2>/dev/null || true
fi
restore() { [ $off = 0 ] || launchctl disable system/com.apple.softwareupdated; rm -f "$M"; }
# with this file there, softwareupdate lists the tools although nothing asked for them in a dialog
M=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
touch "$M"; trap restore EXIT
label=$(softwareupdate -l 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | tail -1)
[ -n "$label" ] || { echo "install-developer-tools: Apple's update server lists no Command Line Tools (softwareupdate -l)" >&2; exit 1; }
echo "install-developer-tools: installing \"$label\""
softwareupdate -i "$label" 2>&1 | grep -v '^$' | tail -4
have || { echo "install-developer-tools: the install ended but clang or git is missing" >&2; exit 1; }
echo "install-developer-tools: $(xcode-select -p): $(clang --version | head -1); $(git --version)"
