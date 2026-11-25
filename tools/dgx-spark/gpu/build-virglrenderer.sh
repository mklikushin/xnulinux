#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build and install virglrenderer with Venus (/usr/local) for xnudrmd's virglrenderer backend.
# Ubuntu 24.04's 1.0.0 fails vkCreateDevice on NVIDIA's driver; 1.2.0 works.
set -euo pipefail
V=1.2.0
W=${W:-$HOME/w/virglrenderer}; mkdir -p "$W"; cd "$W"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential meson ninja-build pkg-config libdrm-dev \
  libepoxy-dev libvulkan-dev libgbm-dev libegl-dev python3-yaml >/dev/null
[ -f virglrenderer-$V.tar.gz ] || curl -sSLo virglrenderer-$V.tar.gz \
  https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/$V/virglrenderer-$V.tar.gz
rm -rf src && mkdir src && tar -C src --strip-components=1 -xf virglrenderer-$V.tar.gz
meson setup src/build src --prefix=/usr/local --buildtype=release -Dvenus=true -Drender-server-worker=thread >/dev/null
ninja -C src/build > ninja.log 2>&1 || { grep -E "error|FAILED" ninja.log | head -30; exit 1; }
sudo ninja -C src/build install >/dev/null
sudo ldconfig
pkg-config --modversion virglrenderer
