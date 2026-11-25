#version 450
// SPDX-License-Identifier: MIT
// layout B, set 0: an immutable sampler at binding 0, a sampled image at binding 1
layout(set = 0, binding = 0) uniform sampler s;
layout(set = 0, binding = 1) uniform texture2D t;
layout(location = 0) out vec4 o;
void main() { o = texture(sampler2D(t, s), vec2(0.5, 0.5)); }
