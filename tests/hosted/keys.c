// SPDX-License-Identifier: GPL-2.0-only
// keys: which pointer-authentication keys are on in this process. Signs one pointer with each key (IA, IB, DA, DB);
// a pointer that comes back unchanged means that key is off. Run it in the hosted macOS.
// build: clang -arch arm64 -o keys-arm64 keys.c ; clang -arch arm64e -o keys-arm64e keys.c
// expected, as on a real Apple silicon Mac:
//   keys-arm64:   IA off  IB off  DA off  DB off
//   keys-arm64e:  IA ON  IB ON  DA ON  DB ON
// "IB ON" or "DB ON" in a plain arm64 process is the bug fixed in xnu-patches/0001 (cswitch.s): see exc.m.
#include <stdio.h>
#include <stdint.h>
#define S(name, enc) __attribute__((noinline)) static uint64_t name(uint64_t p) { register uint64_t x17 __asm__("x17") = p; register uint64_t x16 __asm__("x16") = 0x77; __asm__ volatile(".inst " #enc : "+r"(x17) : "r"(x16)); return x17; }
S(ia, 0xdac10211) S(ib, 0xdac10611) S(da, 0xdac10a11) S(db, 0xdac10e11)
int main(void) { uint64_t p = 0x1234500000; printf("IA %s  IB %s  DA %s  DB %s\n", ia(p) == p ? "off" : "ON", ib(p) == p ? "off" : "ON", da(p) == p ? "off" : "ON", db(p) == p ? "off" : "ON"); return 0; }
