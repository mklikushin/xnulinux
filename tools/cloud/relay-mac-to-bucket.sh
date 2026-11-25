#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# relay-mac-to-bucket.sh [--parts-only] NAME: (on your own machine) send the Mac's ~/MAC_BUILD_DIR/up/NAME/part.* (from
# mac/pack-image.sh or mac/pack-backup.sh) to the Google Cloud Storage bucket BUCKET and prove every part. The Mac gets
# no cloud credentials: this machine makes one resumable upload URL per part and the Mac only PUTs to them.
#   1. the Mac computes MD5 and size of every part
#   2. parts missing in the bucket or with another MD5 are sent; up to 3 rounds
#   3. nothing is composed until every part's bucket MD5 equals the Mac's; a part in the bucket that the Mac does not
#      have stops the run (a stale part from an earlier push once went into an image this way)
#   default: compose NAME.tar.zst from the verified list (32 at a time, the API limit) and check size and part count
#   --parts-only: no compose; NAME/MD5SUMS is written beside the parts (restore: cat the parts in name order)
# Correct parts are skipped, so it is safe to run again after a failure: only what is wrong is sent.
# Needs: gcloud logged in with write access to BUCKET; MAC_HOST, MAC_USER, MAC_KEY. Uploading and storing cost money.
# Exit: 0 every part verified (and composed), 1 failed (the message says which parts), 2 wrong usage or missing setting.
# Status: only syntax-checked in this cleaned form; the private original moved every image and caught a part it was
# given wrong on purpose.
. "$(dirname "$0")/lib.sh"
set -euo pipefail

MODE=compose; if [ "${1:-}" = --parts-only ]; then MODE=parts; shift; fi
[ $# -eq 1 ] || usage_error "usage: relay-mac-to-bucket.sh [--parts-only] NAME"
N=$1; need BUCKET MAC_HOST MAC_USER
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
U=$MAC_BUILD_DIR/up/$N

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

# "part.xx md5-base64 size" per line, from the Mac
mac_ssh "cd '$U' && ls | grep '^part\.' | xargs -P 8 -I{} sh -c 'echo {} \$(openssl md5 -binary {} | base64) \$(stat -f %z {})'" | sort > "$S/want" \
  || die "could not list or hash the parts on the Mac"
[ -s "$S/want" ] || die "no parts in ~/$U on the Mac"
awk 'NF!=3{exit 1}' "$S/want" || die "bad hash line from the Mac: $(awk 'NF!=3' "$S/want" | head -3)"
echo "relay: $(wc -l < "$S/want") parts on the Mac, $(awk '{s+=$3} END{print s}' "$S/want") bytes"

for round in 1 2 3 4; do
  have; todo
  [ -s "$S/todo" ] || break
  [ $round -le 3 ] || die "after 3 rounds these parts still differ from the Mac: $(tr '\n' ' ' < "$S/todo")"
  echo "relay: round $round: sending $(wc -l < "$S/todo") part(s): $(tr '\n' ' ' < "$S/todo")"
  sessions
  mac_ssh "cat > '$U/urls'" < "$S/urls" || die "could not copy the session URLs to the Mac"
  # the HTTP codes are shown but not trusted: the next round's MD5 comparison decides
  mac_ssh "bash -s '$U'; rm -f '$U/urls'" < "$CLOUD_DIR/mac/push-parts.sh" || echo "relay: the push reported an error in round $round (will be re-checked)" >&2
done

extra=$(awk 'FILENAME==ARGV[1]{w[$1]=1; next} !w[$1]{print $1}' "$S/want" "$S/have" | tr '\n' ' ')
[ -z "$extra" ] || die "the bucket has parts the Mac does not (stale, from an earlier push?): $extra -- remove them by hand, nothing was composed"
echo "relay: all $(wc -l < "$S/want") parts match the Mac's MD5"

if [ $MODE = parts ]; then
  "$GCLOUD" storage cp -q "$S/want" "gs://$BUCKET/$N/MD5SUMS" || die "could not write MD5SUMS"
  echo "relay: OK parts-only: gs://$BUCKET/$N/ (MD5SUMS written; restore with: cat part.* | zstd -d | tar -xSf -)"
  exit 0
fi

# compose from the verified list, chaining through the object itself after the first group
first=1
while read -r p _; do echo "gs://$BUCKET/$N/$p"; done < "$S/want" | split -l 31 - "$S/grp."
for g in "$S"/grp.*; do
  if [ $first = 1 ]; then src=$(tr '\n' ' ' < "$g"); first=0; else src="gs://$BUCKET/$N.tar.zst $(tr '\n' ' ' < "$g")"; fi
  # shellcheck disable=SC2086
  "$GCLOUD" storage objects compose $src "gs://$BUCKET/$N.tar.zst" >/dev/null || die "compose failed"
done
read -r size count < <("$GCLOUD" storage objects describe "gs://$BUCKET/$N.tar.zst" --format='value(size,component_count)')
wsize=$(awk '{s+=$3} END{print s}' "$S/want"); wcount=$(wc -l < "$S/want")
[ "$size" = "$wsize" ] || die "composed size $size, expected $wsize"
[ "$count" = "$wcount" ] || die "composed from $count parts, expected $wcount"
echo "relay: OK gs://$BUCKET/$N.tar.zst $size bytes from $count verified parts"
