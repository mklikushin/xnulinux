#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS, as the user who is logged in on its screen: give the display the system's sRGB colour profile.
#
#   sh display-srgb.sh [srgb|reset]      (needs clang: Apple's Command Line Tools, tools/hosted/install-developer-tools.sh)
#
# The hosted display describes itself by its primaries and a 2.2 gamma, and macOS builds a profile of its own from that
# ("xnulinux Display"). Everything drawn in sRGB (nearly all of it) is then converted on its way to the screen, per
# pixel, by the window server, on the CPU. With the sRGB profile the conversion is not needed: with a page animating in
# a full-size Chrome window the window server took 1.7 CPUs instead of 3.3 (switched back and forth within one boot),
# and a transparent, blurred-backdrop browser window drew 12.0 frames a second instead of 11.5. The setting is the
# user's (ColorSync, as System Settings > Displays > Colour profile sets it) and stays across restarts. The display
# driver's DefaultColorSpaceIsSRGB attribute did not do this: the profile and the draws were the same with it.
set -e
d=$(dirname "$0"); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
clang -fobjc-arc -framework Cocoa -framework ColorSync -o "$t/display-srgb" "$d/display-srgb.m"
"$t/display-srgb" "${1:-srgb}"
