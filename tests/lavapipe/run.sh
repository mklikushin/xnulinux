#!/bin/bash
# SPDX-License-Identifier: MIT
# run.sh [ICD.json [test arguments]]: build lvp_push_immutable.c (compiling the three shaders to headers first) and run
# it against one lavapipe build, chosen by its ICD manifest (default: the Vulkan loader's own search). Needs
# glslangValidator, the Vulkan headers and loader, and a C compiler. VULKAN_CFLAGS / VULKAN_LIBS override the default
# "-lvulkan" (for headers and a loader that are not in the system paths).
# Exit: 0 PASS, 1 FAIL (the bug), 2 the test could not set itself up, 3 the build failed.
set -u
cd "$(dirname "$0")" || exit 3
G=$(command -v glslangValidator || command -v glslang) || { echo "run.sh: no glslangValidator" >&2; exit 3; }
for s in vs:vert a:frag b:frag; do n=lvp_push_immutable_${s%:*}
  "$G" -V --vn "$n" -o "$n.h" "$n.${s#*:}" >/dev/null || exit 3
done
# shellcheck disable=SC2086
${CC:-cc} -O1 -Wall ${VULKAN_CFLAGS:-} lvp_push_immutable.c ${VULKAN_LIBS:--lvulkan} -o lvp_push_immutable || exit 3
if [ $# -ge 1 ]; then export VK_DRIVER_FILES=$1 VK_ICD_FILENAMES=$1; shift; fi
./lvp_push_immutable "$@"
