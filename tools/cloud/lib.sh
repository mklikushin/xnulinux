#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Sourced by the tools in this directory: reads the settings (cloud.env beside this file, or the file XNU_CLOUD_ENV names;
# see cloud.env.example) and defines the ssh helpers the tools share. Nothing is run by sourcing it. Exit codes used by
# every tool: 0 done, 1 the operation failed, 2 wrong usage or a missing setting.
CLOUD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLOUD_ENV=${XNU_CLOUD_ENV:-$CLOUD_DIR/cloud.env}
# shellcheck disable=SC1090
if [ -f "$CLOUD_ENV" ]; then . "$CLOUD_ENV"; fi
VM_USER=${VM_USER:-$USER}; VM_KEY=${VM_KEY:-$HOME/.ssh/id_ed25519}; VM_REPO=${VM_REPO:-w/poc}
VM_IMAGE_DIR=${VM_IMAGE_DIR:-/var/tmp/macimg}; GCLOUD=${GCLOUD:-gcloud}
GUEST_USER=${GUEST_USER:-xnu}; GUEST_KEY=${GUEST_KEY:-$HOME/.ssh/id_ed25519}; GUEST_SCREEN=${GUEST_SCREEN:-1280x800}
MAC_KEY=${MAC_KEY:-$HOME/.ssh/id_ed25519}; MAC_BUILD_DIR=${MAC_BUILD_DIR:-xnubuild}
CLOUD_STATE=${XNU_CLOUD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/xnulinux-cloud}

die() { echo "$(basename "$0"): $*" >&2; exit 1; }
usage_error() { echo "$(basename "$0"): $*" >&2; echo "try: $(basename "$0") --help" >&2; exit 2; }
# print the comment block at the top of the calling script (its usage text)
show_help() { sed -n '3,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; }
# need NAME...: stop with exit 2 when a setting is empty
need() { local n; for n in "$@"; do [ -n "${!n:-}" ] || { echo "$(basename "$0"): $n is not set (in $CLOUD_ENV or the environment; see cloud.env.example)" >&2; exit 2; }; done; }
need_file() { [ -r "$1" ] || { echo "$(basename "$0"): cannot read $1 ($2)" >&2; exit 2; }; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$CLOUD_STATE/known_hosts"
  -o ConnectTimeout=30 -o ServerAliveInterval=30)

# the VM's address: VM_HOST, or the cached gcloud lookup
vm_host() {
  if [ -n "${VM_HOST:-}" ]; then echo "$VM_HOST"; return; fi
  mkdir -p "$CLOUD_STATE"
  if [ ! -s "$CLOUD_STATE/vm-host" ]; then
    need GCP_INSTANCE GCP_ZONE
    "$GCLOUD" compute instances describe "$GCP_INSTANCE" --zone "$GCP_ZONE" \
      --format='value(networkInterfaces[0].accessConfigs[0].natIP)' < /dev/null > "$CLOUD_STATE/vm-host.new" || die "gcloud could not look up $GCP_INSTANCE"
    [ -s "$CLOUD_STATE/vm-host.new" ] || die "$GCP_INSTANCE has no external address (is it running?)"
    mv "$CLOUD_STATE/vm-host.new" "$CLOUD_STATE/vm-host"
  fi
  cat "$CLOUD_STATE/vm-host"
}
# vm_ssh 'command': run on the VM
vm_ssh() {
  local h; h=$(vm_host) || exit $?
  mkdir -p "$CLOUD_STATE"; ssh -i "$VM_KEY" "${SSH_OPTS[@]}" "$VM_USER@$h" "$@"
}
vm_scp() {	# vm_scp SRC... DST, with "VM:" standing for the VM
  local h a args=(); h=$(vm_host) || exit $?
  mkdir -p "$CLOUD_STATE"
  for a in "$@"; do args+=("${a/#VM:/$VM_USER@$h:}"); done
  scp -q -i "$VM_KEY" "${SSH_OPTS[@]}" "${args[@]}"
}
# the hosted macOS's address on the VM's xnu0 network (stdin is left alone: callers pipe data or a password through)
guest_ip() {
  if [ -n "${GUEST_IP:-}" ]; then echo "$GUEST_IP"; return; fi
  local ip; ip=$(vm_ssh "awk 'END{print \$3}' /var/lib/misc/dnsmasq.leases 2>/dev/null" < /dev/null) || die "could not reach the VM"
  [ -n "$ip" ] || die "no DHCP lease on the VM yet (is the hosted system up?); or set GUEST_IP"
  echo "$ip"
}
# guest_ssh [ssh options] ['command']: into the hosted macOS, through the VM
guest_ssh() {
  local h g; h=$(vm_host) || exit $?; g=$(guest_ip) || exit $?
  ssh -i "$GUEST_KEY" "${SSH_OPTS[@]}" \
    -o "ProxyCommand=ssh -i $VM_KEY ${SSH_OPTS[*]} -W %h:%p $VM_USER@$h" "$GUEST_USER@$g" "$@"
}
mac_ssh() { need MAC_HOST MAC_USER; mkdir -p "$CLOUD_STATE"; ssh -i "$MAC_KEY" "${SSH_OPTS[@]}" "$MAC_USER@$MAC_HOST" "$@"; }
