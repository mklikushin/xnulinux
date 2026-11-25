#version 450
// SPDX-License-Identifier: MIT
#extension GL_EXT_samplerless_texture_functions : require
// layout A, set 0: two sampled images, no sampler
layout(set = 0, binding = 0) uniform texture2D t0;
layout(set = 0, binding = 1) uniform texture2D t1;
layout(location = 0) out vec4 o;
void main() { o = texelFetch(t0, ivec2(0, 0), 0) * 0.5 + texelFetch(t1, ivec2(1, 0), 0) * 0.5; }
