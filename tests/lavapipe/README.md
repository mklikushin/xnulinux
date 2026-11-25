# Test for the lavapipe push-descriptor fix

`lvp_push_immutable.c` is a plain Vulkan program (no Metal, no macOS needed) for the bug fixed by
`gpu/xnu-cpu-metal/patches/mesa/0002-lavapipe-push-immutable-samplers.patch`: Mesa's lavapipe loses the immutable
sampler of a pushed descriptor set when a set with another layout was pushed at the same index earlier in the command
buffer. In the hosted macOS, where every process renders on the CPU, the same defect crashed the icon service and once
the window server.

These files are MIT, like Mesa and the patch.

| File | What |
|---|---|
| `lvp_push_immutable.c` | The test. Two pipelines with a push-descriptor set 0; the second has an immutable LINEAR sampler. |
| `lvp_push_immutable_vs.vert`, `_a.frag`, `_b.frag` | Its shaders. |
| `run.sh` | Compiles the shaders to headers, builds the test, runs it against the lavapipe you name. |

Build and run:

```sh
sh run.sh /path/to/share/vulkan/icd.d/lvp_icd.aarch64.json
```

or by hand:

```sh
for s in vs.vert a.frag b.frag; do glslangValidator -V --vn lvp_push_immutable_${s%.*} -o lvp_push_immutable_${s%.*}.h lvp_push_immutable_$s; done
cc lvp_push_immutable.c -lvulkan -o lvp_push_immutable
VK_DRIVER_FILES=/path/to/lvp_icd.aarch64.json ./lvp_push_immutable
```

The second pipeline samples the exact centre of a black and white checker, so the right answer is grey (127).

Expected with the fix (exit status 0):

```
push for B carries a SAMPLER write for the immutable binding: yes; texture mip levels: 1
run 1 (control, B only): centre pixel RGBA = 127 127 127 255, expected about 127 127 127 255 -> ok
run 2 (A then B in one command buffer): centre pixel RGBA = 127 127 127 255, expected about 127 127 127 255 -> ok
RESULT: PASS
```

Without the fix (exit status 1):

```
run 1 (control, B only): centre pixel RGBA = 127 127 127 255, expected about 127 127 127 255 -> ok
run 2 (A then B in one command buffer): centre pixel RGBA = 255 255 255 255, expected about 127 127 127 255 -> WRONG
RESULT: FAIL (immutable sampler of the pushed set was lost)
```

The program also prints a `device:` line naming the driver first. Arguments: `nosamplerwrite` (the push for the second
pipeline carries no SAMPLER write) and `mips` (a texture with 7 mip levels); both give the same results.

Where this was measured: on an Apple silicon Mac, against lavapipe built from Mesa 26.3.1 and from Mesa main
(`f8281cfa33e2`, 27.0.0-devel), each with and without the fix. Unfixed builds gave the wrong colour in 6 of 6 runs;
fixed builds passed. On unmodified Mesa the symptom is the wrong colour, not a crash: the crash in the hosted macOS is
the same defect with a sampler index far outside the table. The test was not run on Linux, and `run.sh` is a
cleaned-up form of the script that was used and has only been syntax-checked.
