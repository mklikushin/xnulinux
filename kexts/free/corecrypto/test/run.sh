#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the corecrypto kext's sources for user space with Mbed TLS (MBEDTLS: a checkout of the pinned release; fetched
# when not given) and run test.c against OpenSSL, with AddressSanitizer and UndefinedBehaviorSanitizer.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); K=$D/..; I=$(cd "$K/../../../xnu-patches/corecrypto/include" && pwd)
MBEDTLS_REV=$(sed -n 's/^MBEDTLS_REV=//p' "$K/mbedtls.rev")
W=${W:-$D/build}; mkdir -p "$W"
M=${MBEDTLS:-$W/mbedtls-$MBEDTLS_REV}	# the cache is per pinned commit
if [ ! -d "$M/library" ] && [ -z "${MBEDTLS:-}" ]; then
	rm -rf "$M"; git init -q "$M" && git -C "$M" fetch -q --depth 1 https://github.com/Mbed-TLS/mbedtls "$MBEDTLS_REV" &&
		git -C "$M" checkout -q FETCH_HEAD
fi
HEAD=$(git -C "$M" rev-parse HEAD 2>/dev/null || echo "(not a git checkout)")
[ "$HEAD" = "$MBEDTLS_REV" ] || { echo "Mbed TLS at $M is $HEAD, mbedtls.rev pins $MBEDTLS_REV"; exit 1; }
LIB=$(sed -n 's/^MBEDTLS_SOURCES=//p' "$K/mbedtls.rev")
CC=${CC:-clang}
$CC -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wall -Wextra -Wno-unused-parameter \
	-DCC_TEST_USERSPACE=1 -D_GNU_SOURCE -DMBEDTLS_CONFIG_FILE='"mbedtls_config_xnulinux.h"' -I"$I" -I"$K" -I"$M/include" -I"$M/library" \
	"$D/test.c" "$K"/cc_digest.c "$K"/cc_aes.c "$K"/cc_des.c "$K"/cc_chachapoly.c "$K"/cc_rsa.c "$K"/cc_platform.c \
	"$K"/cc_selftest.c \
	$(for f in $LIB; do echo "$M/library/$f"; done) -lcrypto -o "$W/cctest" > "$W/build.log" 2>&1 ||
	{ head -60 "$W/build.log"; exit 1; }
"$W/cctest"
