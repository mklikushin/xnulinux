// SPDX-License-Identifier: APSL-2.0
/*
 * Copyright (c) 2026 xnulinux contributors. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 * This file contains Original Code and/or Modifications of Original Code as defined in and that are subject to the Apple
 * Public Source License Version 2.0 (the 'License'). You may not use this file except in compliance with the License.
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */
/*
 * The interface between a hosted XNU (the LINUX64 machine layer) and its host, xnu.ko.
 *
 * xnu.ko calls arm_init with linux64_hook set to its entry point. XNU calls into the host with `blr linux64_hook`:
 * x0 = the call (enum linux64_call), x1 and x2 = its arguments; x0 on return is 0 to go on, non-zero when the host ends
 * the run. Requests are in XNU memory (the host and XNU share the kernel address space); `result` fields are filled by
 * the host: a count, or a negative Linux errno.
 *
 * linux64_dbg[] (enum linux64_counter) is read by the host's monitor thread on another CPU while XNU runs.
 *
 * This header is shared by both sides and includes nothing: it is copied into XNU's tree (osfmk/arm64) when the
 * patches are applied, and xnu.ko includes it from here.
 */
#ifndef _LINUX64_ABI_H_
#define _LINUX64_ABI_H_

#define LINUX64_ABI_VERSION 3

enum linux64_call {
	LINUX64_CALL_KERNEL_TABLES  = 210,	/* boot: a1 = XNU's kernel L1 table; the host installs its kernel-range entries */
	LINUX64_CALL_IDLE           = 810,	/* a1 = nanoseconds to XNU's next timer (0: one is due), a2 = this CPU's pending-IPI word
					 * (the host does not sleep while it is set); the host runs Linux meanwhile */
	LINUX64_CALL_PREEMPTED      = 811,	/* a host interrupt is pending: let Linux handle it; a1 = 1 from the kernel, 0 from EL0 */
	LINUX64_CALL_WALLCLOCK      = 812,	/* a1 = u64[2]: {seconds, nanoseconds} UTC */
	LINUX64_CALL_NET_SEND       = 816,	/* a1 = struct linux64_buf_req: one Ethernet frame */
	LINUX64_CALL_NET_RECV       = 817,	/* a1 = struct linux64_buf_req: one Ethernet frame, result 0 when none */
	LINUX64_CALL_INPUT_READ     = 818,	/* a1 = struct linux64_buf_req: whole struct linux64_input_event records */
	LINUX64_CALL_KEYSTORE_RW    = 819,	/* a1 = struct linux64_rw_req on the keystore file */
	LINUX64_CALL_DISK_RW        = 820,	/* a1 = struct linux64_rw_req on the system disk */
	LINUX64_CALL_DISK_SIZE      = 821,	/* a1 = u64 *: the system disk's size in bytes, 0 when there is none */
	LINUX64_CALL_RANDOM         = 822,	/* a1 = buffer, a2 = length: bytes from the host's cryptographic generator */
	LINUX64_CALL_HOSTCALL       = 830,	/* a1 = struct linux64_hostcall_req: a message to a Linux service and its reply */
	LINUX64_CALL_CPU_START      = 840,	/* a1 = a CPU's MPIDR, a2 = its cpu_data_t: the host enters linux64_cpu_entry(a2) there */
	LINUX64_CALL_IPI            = 841,	/* a1 = the target CPU's MPIDR: its linux64_ipi_pending slot is set; make it look */
	LINUX64_CALL_HALT           = 992,	/* the hosted system halts (a1 = 0) or restarts (a1 = 1): the run ends */
	LINUX64_CALL_CONSOLE_READ   = 993,	/* a1 = struct linux64_buf_req: console input bytes */
	LINUX64_CALL_RAMDISK_RW     = 994,	/* a1 = struct linux64_rw_req on the host-file md disk */
	LINUX64_CALL_RAMDISK_SIZE   = 995,	/* a1 = u64 *: the host-file md disk's size, 0 when there is none */
	LINUX64_CALL_CONSOLE_WRITE  = 996,	/* a1 = bytes, a2 = length: /dev/console output */
	LINUX64_CALL_ASSERT         = 997,	/* a1 = struct linux64_assert_info: a failed assert(); non-zero return ends the run */
	LINUX64_CALL_KPRINTF        = 998,	/* a1 = a NUL-terminated line of kprintf/printf output */
	LINUX64_CALL_PANIC          = 999,	/* a1 = the panic message, a2 = the caller; the run ends */
	LINUX64_CALL_USER_ENTER     = 9100,	/* a1 = user pc: the first entry into user space */
};

/* A buffer: bytes to send or room to receive into. */
struct linux64_buf_req {
	void *buf;
	__UINT64_TYPE__ len;
	__INT64_TYPE__ result;
};

/* Reads or writes of a host file at an offset. */
struct linux64_rw_req {
	__UINT64_TYPE__ write;	/* 0: read into buf, 1: write from buf */
	__UINT64_TYPE__ off;
	__UINT64_TYPE__ len;
	void *buf;
	__INT64_TYPE__ result;
};

/* A host call: request and reply in XNU memory. result: the reply's length or -errno. */
struct linux64_hostcall_req {
	const void *req;
	__UINT64_TYPE__ len;
	void *reply;
	__UINT64_TYPE__ max;
	__INT64_TYPE__ result;
};

struct linux64_assert_info {
	const char *file;
	long line;
	const char *expr;
};

/* An input event: Linux evdev's type, code and value. */
struct linux64_input_event {
	unsigned short type;
	unsigned short code;
	int value;
};

/*
 * Per-CPU state shared by XNU and the host lives in arrays indexed by a CPU's slot: affinity 0 and affinity 1 of its
 * MPIDR, four bits each. The host only starts CPUs whose slots differ.
 */
#define LINUX64_CPU_SLOTS 256
#define LINUX64_CPU_SLOT(mpidr) ((unsigned)(((mpidr) & 0xf) | (((mpidr) >> 4) & 0xf0)))

/*
 * linux64_el0_stat[cpu][0][class]: exceptions taken from user space, by class; [cpu][1][class]: counter ticks from
 * taking one until the CPU next enters user space (blocking included). Classes: SVC, data abort, instruction abort,
 * host IRQ, other. By XNU CPU number (cpu_number() & (LINUX64_EL0_CPUS - 1)): small, the kernel's data must not grow.
 */
#define LINUX64_EL0_CLASSES 5
#define LINUX64_EL0_CPUS 8

enum linux64_counter {
	LINUX64_CTR_IDLE_THREAD  = 0,	/* XNU's idle thread loops */
	LINUX64_CTR_MACHINE_IDLE = 1,	/* machine_idle calls */
	LINUX64_CTR_CPU_IDLE     = 2,	/* cpu_idle calls */
	LINUX64_CTR_HOST_IDLE    = 3,	/* LINUX64_CALL_IDLE calls */
	LINUX64_CTR_SWITCHES     = 4,	/* thread_invoke calls */
	LINUX64_CTR_LAST_CALL    = 6,	/* the last enum linux64_call made */
	LINUX64_CTR_RTCLOCK      = 7,	/* timer interrupts delivered */
	LINUX64_CTR_THREAD       = 9,	/* the thread last switched to */
	LINUX64_CTR_EL0_EXC      = 10,	/* exceptions from user space */
	LINUX64_CTR_EL0_ESR      = 11,	/* the last one's ESR, FAR and PC */
	LINUX64_CTR_EL0_FAR      = 12,
	LINUX64_CTR_EL0_PC       = 13,
	LINUX64_CTR_BAD_ESR      = 14,	/* the ESR of an exception the EL0 vectors could not take */
	LINUX64_CTR_DUMP_REQ     = 15,	/* host to XNU: nonzero asks for a thread dump (linux64_dump_threads) at the next idle */
	LINUX64_NCOUNTERS        = 16,
};

#endif /* _LINUX64_ABI_H_ */
