// SPDX-License-Identifier: GPL-2.0-only
/* The virglrenderer backend alone (no fki, no hosted system; address translation stubbed). Run: make test-virgl. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <drm/drm.h>
#include <drm/virtgpu_drm.h>
#include "xnudrmd.h"
int verbose = 2;
int xnudrmd_ranges(void *va, size_t len, struct xnudrm_range *rg, uint32_t *nr)
{
	memset(va, 0x5a, len);
	rg[0].pa = (uintptr_t)va; rg[0].len = len; *nr = 1;
	return 0;
}
int xnudrmd_pin(void *va, size_t len) { return 0; }
void xnudrmd_unpin(void *va) { }
static uint8_t in[1 << 16], out[1 << 16];
static struct xnudrm_hdr rh;
static int call(uint32_t op, uint32_t c, uint64_t a0, uint64_t a1, uint32_t plen)
{
	struct xnudrm_hdr h = { .magic = XNUDRM_MAGIC, .op = op, .client = c, .arg0 = a0, .arg1 = a1, .payload_len = plen };
	uint32_t rlen = 0;
	rh = h;
	vg_serve(&h, in, &rh, out, &rlen);
	printf("op %u arg0 %#llx -> status %d client %u arg0 %#llx rlen %u\n", op, (unsigned long long)a0, rh.status, rh.client, (unsigned long long)rh.arg0, rlen);
	return rh.status;
}
int main(void)
{
	if (vg_init()) return 1;
	call(XNUDRM_OPEN, 0, XNUDRM_VERSION, 0, 0);
	uint32_t c = rh.client;
	struct drm_virtgpu_getparam gp = { .param = VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs, .value = sizeof(gp) };
	memcpy(in, &gp, sizeof(gp));
	call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_GETPARAM, 0, sizeof(gp) + 4);
	printf("capset ids %#x\n", *(int *)(out + sizeof(gp)));
	struct drm_virtgpu_get_caps gc = { .cap_set_id = 4, .addr = sizeof(gc), .size = 160 };
	memcpy(in, &gc, sizeof(gc));
	call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_GET_CAPS, 0, sizeof(gc) + 160);
	uint32_t *caps = (uint32_t *)(out + sizeof(gc));
	printf("venus caps: wire %u vk_xml %#x ext_command_serialization %u mesa_venus_protocol %u supports_blob_id_0 %u\n", caps[0], caps[1], caps[2], caps[3], caps[4]);
	struct { struct drm_virtgpu_context_init ci; struct drm_virtgpu_context_set_param sp; } ci = { { .num_params = 1, .ctx_set_params = sizeof(ci.ci) }, { VIRTGPU_CONTEXT_PARAM_CAPSET_ID, 4 } };
	memcpy(in, &ci, sizeof(ci));
	if (call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_CONTEXT_INIT, 0, sizeof(ci))) return 1;
	struct drm_virtgpu_resource_create_blob cb = { .blob_mem = VIRTGPU_BLOB_MEM_HOST3D, .blob_flags = VIRTGPU_BLOB_FLAG_USE_MAPPABLE, .size = 1 << 20 };
	memcpy(in, &cb, sizeof(cb));
	if (call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_CREATE_BLOB, 0, sizeof(cb))) return 1;
	uint32_t h = ((struct drm_virtgpu_resource_create_blob *)out)->bo_handle;
	printf("blob handle %u\n", h);
	if (call(XNUDRM_MAP, c, h, 1 << 20, 0)) return 1;
	struct drm_virtgpu_execbuffer eb = { .flags = VIRTGPU_EXECBUF_FENCE_FD_OUT };
	memcpy(in, &eb, sizeof(eb));
	if (call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_EXECBUFFER, 0, sizeof(eb))) return 1;
	int f = ((struct drm_virtgpu_execbuffer *)out)->fence_fd, i;
	/* a fence closed without a wait, then the next one in its slot */
	call(XNUDRM_FENCE_CLOSE, c, f, 0, 0);
	memcpy(in, &eb, sizeof(eb));
	if (call(XNUDRM_IOCTL, c, DRM_COMMAND_BASE + DRM_VIRTGPU_EXECBUFFER, 0, sizeof(eb))) return 1;
	f = ((struct drm_virtgpu_execbuffer *)out)->fence_fd;
	for (i = 0; i < 20 && call(XNUDRM_FENCE_WAIT, c, f, 50000000, 0); i++) ;
	call(XNUDRM_FENCE_CLOSE, c, f, 0, 0);
	struct drm_gem_close gcl = { .handle = h };
	memcpy(in, &gcl, sizeof(gcl));
	call(XNUDRM_IOCTL, c, 0x09, 0, sizeof(gcl));
	call(XNUDRM_CLOSE, c, 0, 0, 0);
	return i == 20;
}
