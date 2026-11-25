// SPDX-License-Identifier: GPL-2.0-only
// How long a one-second wait really takes, by the wall clock, through the interfaces macOS programs use. A Mac's counter
// runs at 24 MHz (mach_timebase_info 125/3) and parts of macOS assume it; a host whose counter runs at another rate (1 GHz
// on Arm's newer cores) has to be scaled by the hosted kernel (xnu.ko does it since "Hosted on a machine that is not a
// Mac"; the boot argument droidvm-timebase-hz=24000000 asks the kernel for the same). Without that the last line, a wait
// for 24,000,000 ticks, returns after 24 ms, and the hosted system never goes idle.
//
//   clang -o timers timers.c && ./timers
//
// Prints the six waits in milliseconds and exits 0 when each took between 0.9 and 1.5 seconds.
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/time.h>
#include <sys/event.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>

static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e3 + tv.tv_usec / 1e3; }
static int bad;
static void report(const char *what, double ms) { int ok = ms > 900 && ms < 1500; if (!ok) bad = 1; printf("%-4s %-38s %6.0f ms\n", ok ? "ok" : "FAIL", what, ms); }

int main(void) {
  double t;
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  printf("     mach_timebase_info %u/%u\n", tb.numer, tb.denom);
  t = now(); usleep(1000000); report("usleep(1 s)", now() - t);
  { dispatch_semaphore_t s = dispatch_semaphore_create(0); t = now();
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)); report("dispatch_semaphore_wait(1 s)", now() - t); }
  { dispatch_semaphore_t s = dispatch_semaphore_create(0); t = now();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ dispatch_semaphore_signal(s); });
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER); report("dispatch_after(1 s)", now() - t); }
  { pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER; pthread_cond_t c = PTHREAD_COND_INITIALIZER; struct timespec rel = {1, 0};
    pthread_mutex_lock(&m); t = now(); pthread_cond_timedwait_relative_np(&c, &m, &rel); report("pthread_cond_timedwait_relative_np(1 s)", now() - t); }
  { int kq = kqueue(); struct kevent ev, out; EV_SET(&ev, 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, 1000, 0);
    t = now(); kevent(kq, &ev, 1, &out, 1, NULL); report("kevent EVFILT_TIMER(1000 ms)", now() - t); }
  { uint64_t a = mach_absolute_time(); t = now(); mach_wait_until(a + 24000000ull); report("mach_wait_until(now + 24,000,000 ticks)", now() - t); }
  return bad;
}
