// SPDX-License-Identifier: MIT
// lvp_push_immutable: lavapipe loses the immutable samplers of a pushed descriptor set when a set with ANOTHER layout was
// bound at the same set index earlier in the command buffer (handle_push_descriptor_set memcpy()s the old set over the new one).
//
// Two pipelines, both with a push-descriptor set 0:
//   A: binding 0 SAMPLED_IMAGE, binding 1 SAMPLED_IMAGE            (texelFetch only)
//   B: binding 0 SAMPLER with an immutable LINEAR sampler, binding 1 SAMPLED_IMAGE
// The texture is a 64x64 black/white checker of 32x32 blocks; B samples its exact centre, so LINEAR gives 0.5 grey (127/128)
// and anything else (NEAREST, another sampler, garbage) gives something else or crashes in JIT code.
//   run 1 (control): one command buffer, only  push B + draw B          -> expect grey
//   run 2 (bug):     one command buffer, push A + draw A, push B + draw B -> expect grey; unfixed lavapipe: crash / wrong colour
// usage: lvp_push_immutable [nosamplerwrite] [mips]
//   default: the push for B also carries a SAMPLER write for binding 0; the texture has one mip level.
//   mips: the texture has 7 mip levels (only level 0 has data; the immutable sampler has maxLod 0, so the expected result is the same).
//         This changes the stale bytes B reads as its sampler.
// build and run: see README.md beside this file (run.sh does it)
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lvp_push_immutable_vs.h"
#include "lvp_push_immutable_a.h"
#include "lvp_push_immutable_b.h"
#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "FAILED %s = %d (line %d)\n", #x, r_, __LINE__); exit(2); } } while (0)
#define W 16
#define TW 64
static VkPhysicalDevice pd; static VkDevice dev;
static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags want) {
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++) if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
  fprintf(stderr, "no memory type\n"); exit(2); }
static VkImage mkimage(VkFormat f, uint32_t w, uint32_t mips, VkImageUsageFlags u, VkImageView *view) {
  VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = f, .extent = { w, w, 1 }, .mipLevels = mips, .arrayLayers = 1,
    .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = u, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
  VkImage im; CK(vkCreateImage(dev, &ci, NULL, &im));
  VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, im, &mr);
  VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = memtype(mr.memoryTypeBits, 0) };
  VkDeviceMemory m; CK(vkAllocateMemory(dev, &ai, NULL, &m)); CK(vkBindImageMemory(dev, im, m, 0));
  VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = im, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = f,
    .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, mips, 0, 1 } };
  CK(vkCreateImageView(dev, &vi, NULL, view)); return im; }
static VkBuffer mkbuffer(VkDeviceSize size, VkBufferUsageFlags u, void **map) {
  VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = u };
  VkBuffer b; CK(vkCreateBuffer(dev, &ci, NULL, &b));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, b, &mr);
  VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
    .memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
  VkDeviceMemory m; CK(vkAllocateMemory(dev, &ai, NULL, &m)); CK(vkBindBufferMemory(dev, b, m, 0)); CK(vkMapMemory(dev, m, 0, size, 0, map)); return b; }
static VkShaderModule mkshader(const uint32_t *code, size_t bytes) {
  VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes, .pCode = code };
  VkShaderModule m; CK(vkCreateShaderModule(dev, &ci, NULL, &m)); return m; }
static VkPipeline mkpipeline(VkShaderModule vs, VkShaderModule fs, VkPipelineLayout pl, VkRenderPass rp) {
  VkPipelineShaderStageCreateInfo st[2] = {
    { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
    { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" } };
  VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
  VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
  VkViewport vp = { 0, 0, W, W, 0, 1 }; VkRect2D sc = { { 0, 0 }, { W, W } };
  VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
  VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
  VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
  VkPipelineColorBlendAttachmentState ba = { .colorWriteMask = 0xf };
  VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ba };
  VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
    .pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = pl, .renderPass = rp };
  VkPipeline p; CK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p)); return p; }

int main(int argc, char **argv) {
  int samplerwrite = 1; uint32_t mips = 1;
  for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "nosamplerwrite")) samplerwrite = 0; if (!strcmp(argv[i], "mips")) mips = 7; }
  setvbuf(stdout, NULL, _IONBF, 0);
  VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "lvp_push_immutable", .apiVersion = VK_API_VERSION_1_2 };
  VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
  VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
  uint32_t n = 1; VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd); if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n < 1) { fprintf(stderr, "no device\n"); return 2; }
  VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pd, &pp);
  VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
  VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &p12 }; vkGetPhysicalDeviceProperties2(pd, &p2);
  printf("device: %s | driver: %s %s | api %u.%u.%u\n", pp.deviceName, p12.driverName, p12.driverInfo, VK_VERSION_MAJOR(pp.apiVersion), VK_VERSION_MINOR(pp.apiVersion), VK_VERSION_PATCH(pp.apiVersion));
  float prio = 1; VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
  const char *ext[] = { VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME };
  VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = ext };
  CK(vkCreateDevice(pd, &dci, NULL, &dev));
  VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
  PFN_vkCmdPushDescriptorSetKHR push = (PFN_vkCmdPushDescriptorSetKHR)vkGetDeviceProcAddr(dev, "vkCmdPushDescriptorSetKHR");
  if (!push) { fprintf(stderr, "no vkCmdPushDescriptorSetKHR\n"); return 2; }

  VkImageView rtv, texv;
  VkImage rt = mkimage(VK_FORMAT_R8G8B8A8_UNORM, W, 1, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &rtv);
  VkImage tex = mkimage(VK_FORMAT_R8G8B8A8_UNORM, TW, mips, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, &texv);
  void *stmap, *rbmap;
  VkBuffer staging = mkbuffer(TW * TW * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &stmap);
  VkBuffer readback = mkbuffer(W * W * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &rbmap);
  for (int y = 0; y < TW; y++) for (int x = 0; x < TW; x++) { uint8_t v = ((x / 32) ^ (y / 32)) & 1 ? 0 : 255; uint8_t *p = (uint8_t *)stmap + (y * TW + x) * 4; p[0] = p[1] = p[2] = v; p[3] = 255; }

  // a few unrelated samplers first, so the immutable one is not index 0 in the driver's tables
  VkSampler other[4], lin;
  for (int i = 0; i < 4; i++) { VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST,
      .addressModeU = (VkSamplerAddressMode)i, .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT, .maxLod = (float)i };
    CK(vkCreateSampler(dev, &sci, NULL, &other[i])); }
  VkSamplerCreateInfo lci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR, .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
    .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE };
  CK(vkCreateSampler(dev, &lci, NULL, &lin));

  VkDescriptorSetLayoutBinding ba[2] = { { 0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL }, { 1, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL } };
  VkDescriptorSetLayoutBinding bb[2] = { { 0, VK_DESCRIPTOR_TYPE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, &lin }, { 1, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL } };
  VkDescriptorSetLayoutCreateInfo la = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, .bindingCount = 2, .pBindings = ba };
  VkDescriptorSetLayoutCreateInfo lb = la; lb.pBindings = bb;
  VkDescriptorSetLayout dla, dlb; CK(vkCreateDescriptorSetLayout(dev, &la, NULL, &dla)); CK(vkCreateDescriptorSetLayout(dev, &lb, NULL, &dlb));
  VkPipelineLayoutCreateInfo pla = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dla }, plb = pla; plb.pSetLayouts = &dlb;
  VkPipelineLayout PLA, PLB; CK(vkCreatePipelineLayout(dev, &pla, NULL, &PLA)); CK(vkCreatePipelineLayout(dev, &plb, NULL, &PLB));

  VkAttachmentDescription att = { .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
    .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
  VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
  VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ref };
  VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
  VkRenderPass rp; CK(vkCreateRenderPass(dev, &rpci, NULL, &rp));
  VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp, .attachmentCount = 1, .pAttachments = &rtv, .width = W, .height = W, .layers = 1 };
  VkFramebuffer fb; CK(vkCreateFramebuffer(dev, &fci, NULL, &fb));
  VkShaderModule vs = mkshader(lvp_push_immutable_vs, sizeof(lvp_push_immutable_vs)), fa = mkshader(lvp_push_immutable_a, sizeof(lvp_push_immutable_a)), fbm = mkshader(lvp_push_immutable_b, sizeof(lvp_push_immutable_b));
  VkPipeline PA = mkpipeline(vs, fa, PLA, rp), PB = mkpipeline(vs, fbm, PLB, rp);

  VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
  VkCommandPool pool; CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
  VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
  VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &cai, &cb));
  VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
  VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };

  // upload the checker
  CK(vkBeginCommandBuffer(cb, &bi));
  VkImageMemoryBarrier b1 = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = tex, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, mips, 0, 1 } };
  vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b1);
  VkBufferImageCopy reg = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { TW, TW, 1 } };
  vkCmdCopyBufferToImage(cb, staging, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &reg);
  b1.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; b1.dstAccessMask = VK_ACCESS_SHADER_READ_BIT; b1.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b1.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &b1);
  CK(vkEndCommandBuffer(cb)); CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE)); CK(vkQueueWaitIdle(q));

  VkDescriptorImageInfo ii = { .imageView = texv, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL }, sinfo = { .sampler = lin };
  VkWriteDescriptorSet wa[2] = {
    { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &ii },
    { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &ii } };
  VkWriteDescriptorSet wb[2] = {
    { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &ii },
    { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER, .pImageInfo = &sinfo } };
  printf("push for B carries a SAMPLER write for the immutable binding: %s; texture mip levels: %u\n", samplerwrite ? "yes" : "no", mips);
  int bad = 0;
  for (int run = 1; run <= 2; run++) {
    printf("run %d (%s): ", run, run == 1 ? "control, B only" : "A then B in one command buffer");
    CK(vkBeginCommandBuffer(cb, &bi));
    VkClearValue cv = { .color = { .float32 = { 0, 0, 1, 1 } } };
    VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb, .renderArea = { { 0, 0 }, { W, W } }, .clearValueCount = 1, .pClearValues = &cv };
    vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    if (run == 2) {
      vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, PA);
      push(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, PLA, 0, 2, wa);
      vkCmdDraw(cb, 3, 1, 0, 0);
    }
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, PB);
    push(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, PLB, 0, samplerwrite ? 2 : 1, wb);
    vkCmdDraw(cb, 3, 1, 0, 0);
    vkCmdEndRenderPass(cb);
    VkBufferImageCopy rr = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, W, 1 } };
    vkCmdCopyImageToBuffer(cb, rt, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &rr);
    CK(vkEndCommandBuffer(cb)); CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE)); CK(vkQueueWaitIdle(q));
    uint8_t *p = (uint8_t *)rbmap + ((W / 2) * W + W / 2) * 4;
    int ok = p[0] >= 120 && p[0] <= 135 && p[1] == p[0] && p[2] == p[0];
    printf("centre pixel RGBA = %u %u %u %u, expected about 127 127 127 255 -> %s\n", p[0], p[1], p[2], p[3], ok ? "ok" : "WRONG");
    bad |= !ok;
  }
  printf(bad ? "RESULT: FAIL (immutable sampler of the pushed set was lost)\n" : "RESULT: PASS\n");
  return bad; }
