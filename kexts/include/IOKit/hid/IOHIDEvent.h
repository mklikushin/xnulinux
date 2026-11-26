// SPDX-License-Identifier: APSL-2.0
// IOHIDFamily's IOKit/hid/IOHIDEvent.h is not in the SDK's Kernel.framework, and IOKit/hidevent/IOHIDEventService.h
// includes it when KERNEL_PRIVATE is defined. The kexts here only pass events on by pointer: the names are enough.
#ifndef XNULINUX_IOHIDEVENT_STUB_H
#define XNULINUX_IOHIDEVENT_STUB_H
#include <libkern/c++/OSObject.h>
class IOHIDEvent;
typedef uint32_t IOHIDEventType;
#endif
