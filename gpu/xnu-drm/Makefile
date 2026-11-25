# SPDX-License-Identifier: GPL-2.0-only
# The Linux end (xnudrmd); the macOS ends are kexts/XnuDrm and darwin/ (libxnudrm, built with Mesa).
# With libvirglrenderer installed (pkg-config), xnudrmd also serves a render node that is not virtio-gpu.
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
VIRGL ?= $(shell pkg-config --exists virglrenderer && echo 1)
SRC = xnudrmd.c
ifeq ($(VIRGL),1)
SRC += xnudrmd_virgl.c
CFLAGS += -DXNUDRM_VIRGL $(shell pkg-config --cflags virglrenderer)
LDLIBS += $(shell pkg-config --libs virglrenderer)
endif
xnudrmd: $(SRC) xnudrm_proto.h xnudrmd.h
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)
# the backend alone, on the host's Vulkan driver (no fki, no hosted system)
test-virgl: test/virgl_smoke.c xnudrmd_virgl.c xnudrm_proto.h xnudrmd.h
	$(CC) $(CFLAGS) -I. -o test/virgl_smoke test/virgl_smoke.c xnudrmd_virgl.c $(LDLIBS)
	test/virgl_smoke
clean:
	rm -f xnudrmd test/virgl_smoke
