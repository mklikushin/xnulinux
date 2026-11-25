#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the hosted macOS: build keys.c and exc.m as arm64 and as arm64e, run them, and compare with what a real Apple silicon
# Mac gives: plain arm64 processes run with all four pointer-authentication keys off, arm64e ones with all four on, and
# both catch 50 of 50 exceptions. Copy this directory into the guest and run: sh run.sh
# A guest with no compiler (a disk built on Linux has none): build the four programs where there is one, with the two
# clang lines below, name them keys-arm64, keys-arm64e, exc-arm64, exc-arm64e, and give their folder: sh run.sh FOLDER
# Prints "hosted tests: pass" and exits 0, or says which check failed and exits 1. Half a minute; first compile is slow.
set -u
cd "$(dirname "$0")" || exit 1
P=${1:-}; O=$(mktemp -d); trap 'rm -rf "$O"' EXIT; bad=0
check() { [ "$2" = "$3" ] && echo "ok   $1: $2" || { echo "FAIL $1: got '$2', expected '$3'"; bad=1; }; }
for a in arm64 arm64e; do
  if [ -n "$P" ]; then
    cp "$P/keys-$a" "$P/exc-$a" "$O/" || { echo "FAIL no prebuilt keys-$a and exc-$a in $P"; bad=1; continue; }
  else
    clang -arch $a -o "$O/keys-$a" keys.c && clang -arch $a -framework Foundation -o "$O/exc-$a" exc.m || { echo "FAIL build $a"; bad=1; continue; }
  fi
  [ $a = arm64 ] && want="IA off  IB off  DA off  DB off" || want="IA ON  IB ON  DA ON  DB ON"
  check "keys $a" "$("$O/keys-$a")" "$want"
  check "exc $a" "$("$O/exc-$a" 2>&1 | tail -1)" "caught 50 of 50 exceptions"
done
[ $bad = 0 ] && echo "hosted tests: pass" || { echo "hosted tests: FAIL"; exit 1; }
