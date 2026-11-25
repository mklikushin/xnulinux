#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# boot-cycle.sh N LABEL [OBSERVE_SECONDS=240]: (on your own machine) reboot the hosted macOS N times and, OBSERVE_SECONDS
# after each desktop comes up, record one line: is the Dock up, how long the window server has lived (younger than the
# boot = it crashed and restarted), and how many crash reports were written since that boot, by process name. For
# telling an intermittent crash from a fixed one: compare the counts of a few boots before and after a change.
# Lines are appended to BOOT_CYCLE_LOG (default ./boot-cycle.log). Uses VM_IMAGE_DIR and guest-ssh.
# It STOPS AND STARTS the hosted system: do not run it while anything else uses it. Each cycle takes about
# OBSERVE_SECONDS plus two minutes.
# Exit: 0 all cycles recorded, 1 a boot did not reach the Dock, 2 wrong usage.
# Status: run in this form: four reboots with a 180 s observation each, and the read-only check (N=0). The private
# original counted the dumps of a debugging build of the renderer instead of crash reports.
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { show_help; exit 0; }
[ $# -ge 2 ] || usage_error "usage: boot-cycle.sh N LABEL [observe-seconds]"
N=$1; L=$2; W=${3:-240}; LOG=${BOOT_CYCLE_LOG:-boot-cycle.log}
case "$N$W" in *[!0-9]*) usage_error "N and observe-seconds must be numbers";; esac
# shellcheck disable=SC2016
CHECK='b=$(sysctl -n kern.boottime | sed "s/.*{ sec = \([0-9]*\),.*/\1/"); m=$(( ($(date +%s) - b) / 60 + 1 ))
r=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name "*.ips" -mmin -$m 2>/dev/null | sed "s|.*/||; s/-20[0-9][0-9]-.*//; s/_20[0-9][0-9]-.*//" | sort | uniq -c | awk "{printf \"%s=%s \", \$2, \$1}")
d=$(pgrep -x Dock >/dev/null && echo up || echo DOWN); ws=$(ps -axo etime=,comm= | grep "WindowServer\$" | awk "{print \$1}")
echo "dock=$d windowserver-age=$ws up-min=$m crash-reports: ${r:-none}"'
if [ "$N" = 0 ]; then guest_ssh "$CHECK"; exit; fi	# N=0: only the check, on the running system (changes nothing)
rc=0
for i in $(seq 1 "$N"); do
  timeout 30 "$CLOUD_DIR/guest-ssh" 'sync; sync' >/dev/null 2>&1
  vm_ssh "cd ~/'$VM_REPO' && bash scripts/xnulinux-boot.sh stop" >/dev/null 2>&1
  XNU_CLOUD_ENV=$CLOUD_ENV "$CLOUD_DIR/vm-run" "$CLOUD_DIR/vm/boot-image.sh" "$VM_IMAGE_DIR" 45 >/dev/null 2>&1
  n=0; until [ $n -ge 40 ] || timeout 25 "$CLOUD_DIR/guest-ssh" 'pgrep -x Dock' >/dev/null 2>&1; do n=$((n+1)); sleep 6; done
  if [ $n -ge 40 ]; then r="NO DESKTOP after 4 minutes"; rc=1; else
    r=$(timeout $((W+60)) "$CLOUD_DIR/guest-ssh" "sleep $W; $CHECK" 2>&1 | tail -1); fi
  echo "$(date +%H:%M:%S) $L boot $i/$N: $r" | tee -a "$LOG"
done
exit $rc
