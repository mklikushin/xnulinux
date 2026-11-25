// SPDX-License-Identifier: GPL-2.0-only
// In the hosted macOS: write a distinct value into every 16 KB page of N GiB, then read them all back (twice, the second time after the
// compressor has had a chance to take some). Exit 0 when every page reads back what was written.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/mman.h>
#include <mach/mach_time.h>
int main(int argc, char **argv) {
  size_t gib = argc > 1 ? strtoul(argv[1], 0, 0) : 4, n = gib << 30, step = 16384, bad = 0;
  uint64_t *p = mmap(0, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); return 2; }
  for (size_t o = 0; o < n; o += step) { uint64_t *q = (uint64_t *)((char *)p + o); q[0] = o ^ 0x5a5a5a5a5a5a5a5aull; q[step / 8 - 1] = ~o; }
  for (int pass = 0; pass < 2; pass++)
    for (size_t o = 0; o < n; o += step) { uint64_t *q = (uint64_t *)((char *)p + o); if (q[0] != (o ^ 0x5a5a5a5a5a5a5a5aull) || q[step / 8 - 1] != ~o) bad++; }
  printf("%zu GiB: %zu pages written, read back twice, %zu bad\n", gib, n / step, bad);
  return bad != 0;
}
