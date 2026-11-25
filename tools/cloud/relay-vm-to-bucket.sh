#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# relay-vm-to-bucket.sh NAME [VM_OUT_DIR=/var/tmp/up]: (on your own machine) send the cloud VM's VM_OUT_DIR/NAME/part.*
# (from vm/save-image.sh, with its WANT file) to the bucket BUCKET as NAME/part.* and prove every part. Same checks as
# relay-mac-to-bucket.sh --parts-only with the VM as the source: parts whose bucket MD5 differs are sent through fresh
# resumable upload URLs, up to 3 rounds, six at a time; then NAME/MD5SUMS is written. The VM needs no write access to
# the bucket. Safe to run again: correct parts are skipped. Uploading and storing cost money.
# Restore on a VM: cat the parts in name order | zstd -d | tar -xSf -
# Exit: 0 every part verified, 1 failed, 2 wrong usage or missing setting.
# Status: only syntax-checked in this cleaned form; the private original sent 28 parts (29 GB) in 148 s, all matching.
. "$(dirname "$0")/lib.sh"
set -euo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || usage_error "usage: relay-vm-to-bucket.sh NAME [VM_OUT_DIR]"
N=$1; U=${2:-/var/tmp/up}/$N; need BUCKET
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

have() { "$GCLOUD" storage objects list "gs://$BUCKET/$N/part.*" --format="value(name.basename(),md5_hash,size)" 2>/dev/null | awk "{print \$1, \$2, \$3}" | sort > "$S/have" || true; }
# parts whose bucket MD5 or size differs from the source, or that the bucket lacks (FILENAME test: an empty listing must not
# make every part look present)
todo() { awk 'FILENAME==ARGV[1]{h[$1]=$2" "$3; next} h[$1]!=$2" "$3{print $1}' "$S/have" "$S/want" > "$S/todo"; }
# one resumable upload session URL per part in todo -> $S/urls ("part URL" per line)
sessions() {
  local TOK p loc; TOK=$("$GCLOUD" auth print-access-token) || die "gcloud has no login (gcloud auth login)"; : > "$S/urls"
  while read -r p; do
    loc=$(curl -sS -D - -o /dev/null -X POST -H @<(printf "Authorization: Bearer %s\n" "$TOK") -H "Content-Length: 0" -H "X-Upload-Content-Type: application/octet-stream" \
      "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=resumable&name=$N/$p" | tr -d "\r" | awk 'tolower($1)=="location:"{print $2}')
    [ -n "$loc" ] || die "no upload session for $p (bucket name and write access?)"
    echo "$p $loc" >> "$S/urls"
  done < "$S/todo"
}
vm_ssh "cat '$U/WANT'" | sort > "$S/want" || die "could not read $U/WANT on the VM (run vm/save-image.sh first)"
[ -s "$S/want" ] || die "empty WANT in $U on the VM"
awk 'NF!=3{exit 1}' "$S/want" || die "bad line in WANT: $(awk 'NF!=3' "$S/want" | head -3)"
echo "relay: $(wc -l < "$S/want") parts on the VM, $(awk '{s+=$3} END{print s}' "$S/want") bytes"
for round in 1 2 3 4; do
  have; todo
  [ -s "$S/todo" ] || break
  [ $round -le 3 ] || die "after 3 rounds these parts still differ from the VM: $(tr '\n' ' ' < "$S/todo")"
  echo "relay: round $round: sending $(wc -l < "$S/todo") part(s)"
  sessions
  vm_ssh "cat > '$U/urls'" < "$S/urls" || die "could not copy the session URLs to the VM"
  # the HTTP codes are shown but not trusted: the next round's MD5 comparison decides
  vm_ssh "cd '$U' && t=\$(date +%s) && xargs -P 6 -L 1 sh -c 'c=\$(curl -sS -o /dev/null -w \"%{http_code}\" -X PUT -H \"Content-Type: application/octet-stream\" -T \"\$0\" \"\$1\"); echo \"\$0 \$c\"' < urls | tr '\n' ' '; rm -f urls; echo; echo \"pushed in \$(( \$(date +%s) - t )) s\"" \
    || echo "relay: the push reported an error in round $round (will be re-checked)" >&2
done
extra=$(awk 'FILENAME==ARGV[1]{w[$1]=1; next} !w[$1]{print $1}' "$S/want" "$S/have" | tr '\n' ' ')
[ -z "$extra" ] || die "the bucket has parts the VM does not: $extra -- remove them by hand"
"$GCLOUD" storage cp -q "$S/want" "gs://$BUCKET/$N/MD5SUMS" || die "could not write MD5SUMS"
echo "relay: OK gs://$BUCKET/$N/: all $(wc -l < "$S/want") parts match the VM's MD5; MD5SUMS written"
