// SPDX-License-Identifier: GPL-2.0-only
// exc: Objective-C exceptions thrown and caught through this binary's own frames, 50 times. Run it in the hosted macOS.
// A plain arm64 binary's return addresses are unsigned; the system unwinder (arm64e) authenticates them with the IB key,
// which must therefore be off in arm64 processes. With IB on, a CPU with FEAT_FPAC kills the process at the first throw.
// build: clang -arch arm64 -framework Foundation -o exc-arm64 exc.m   (and -arch arm64e for the control)
// expected (arm64):  IB sign of 0x1234500000 -> 0x1234500000 (IB key OFF: no-op)
//                    IA sign -> 0x1234500000 (IA key OFF)
//                    caught 50 of 50 exceptions
// expected (arm64e): both keys ON, caught 50 of 50 exceptions
// failure (arm64, before the fix): "IB key ON", then the process dies with SIGBUS (EXC_ARM_PAC_FAIL in the crash report)
#import <Foundation/Foundation.h>
#include <stdint.h>
// pacia1716 / pacib1716 are in the hint space, so they assemble for plain arm64 too
__attribute__((noinline)) static void *sign(void *p, int b) { register void *x17 __asm__("x17") = p; register uint64_t x16 __asm__("x16") = 0x77;
  if (b) __asm__ volatile("hint #10" : "+r"(x17) : "r"(x16)); else __asm__ volatile("hint #8" : "+r"(x17) : "r"(x16)); return x17; }
__attribute__((noinline)) static void thrower(int n) { if (n == 0) @throw [NSException exceptionWithName:@"T" reason:@"test" userInfo:nil]; thrower(n - 1); NSLog(@"unreachable %d", n); }
__attribute__((noinline)) static int mid(int n) { @autoreleasepool { thrower(n); } return n; }
int main(void) { @autoreleasepool {
  void *p = (void *)0x1234500000; void *s = sign(p, 1);
  setvbuf(stdout, 0, _IONBF, 0); printf("IB sign of %p -> %p (%s)\n", p, s, p == s ? "IB key OFF: no-op" : "IB key ON");
  void *a = sign(p, 0); printf("IA sign -> %p (%s)\n", a, p == a ? "IA key OFF" : "IA key ON");
  int ok = 0; for (int i = 0; i < 50; i++) { @try { mid(3 + (i % 5)); } @catch (NSException *e) { ok++; } }
  printf("caught %d of 50 exceptions\n", ok); } return 0; }
