#version 450
// SPDX-License-Identifier: MIT
void main() { vec2 q = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2); gl_Position = vec4(q * 2.0 - 1.0, 0.0, 1.0); }
