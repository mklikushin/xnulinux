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
// A key counts as off only when it leaves all of 16 pointers unchanged. One pointer is not enough: while hosted the keys
// are the boot's, the same in every process, and a signature is 7 bits (bits 54 to 48), so about one boot in 128 signs
// any one pointer with zero and every run of that boot said "off" for that key (seen once: IB, 400 runs of 400).
static int on(uint64_t (*sign)(uint64_t)) { for (uint64_t i = 0; i < 16; i++) { uint64_t p = 0x1234500000 + (i << 12); if (sign(p) != p) return 1; } return 0; }
int main(void) { printf("IA %s  IB %s  DA %s  DB %s\n", on(ia) ? "ON" : "off", on(ib) ? "ON" : "off", on(da) ? "ON" : "off", on(db) ? "ON" : "off"); return 0; }
