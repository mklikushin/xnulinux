#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS, as the logged-in user: bind the hosted display (IOMFBUUID 44726F69-6456-4D00-0000-000000000001)
# to the system's sRGB profile via defaults (no clang / Command Line Tools required). Takes effect on next login/restart.
#
#   sh display-srgb.sh [srgb|reset]
#
# macOS synthesizes a custom ICC profile ("xnulinux Display-<UUID>.icc") for AppleParavirtDisplay that fails
# CGColorSpaceEqualToColorSpace(..., kCGColorSpaceSRGB), forcing WindowServer to run a per-pixel color-conversion shader
# on sRGB surfaces on the CPU. Binding sRGB Profile.icc halves Chrome's WindowServer CPU (~332% -> ~175% at 60 fps) and
# nudges a transparent/blurred browser window from ~11.5 to ~12.0 fps.
set -e
DEV="Device.mntr.44726F69-6456-4D00-0000-000000000001"
case "${1:-srgb}" in
  srgb)
    defaults -currentHost write -g com.apple.ColorSync.Devices -dict-add "$DEV" \
      '<dict><key>CustomProfiles</key><dict><key>1</key><string>/System/Library/ColorSync/Profiles/sRGB Profile.icc</string></dict></dict>'
    echo "set sRGB profile for $DEV (takes effect on next login/restart)"
    ;;
  reset)
    defaults -currentHost delete -g com.apple.ColorSync.Devices 2>/dev/null || true
    echo "cleared custom ColorSync device profiles (takes effect on next login/restart)"
    ;;
  *)
    echo "usage: $0 [srgb|reset]" >&2
    exit 2
    ;;
esac
