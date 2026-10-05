#!/bin/bash
# Usage: io-paths.sh <libkrun_dir> [reclaim]
#
# Diagnostic, not a pass/fail test: which guest I/O paths grow krunkit's own memory
# (its mapped regions, as opposed to guest RAM)?
#   - streaming data into the guest over the Docker socket (vsock)
#   - heavy writes to the guest disk (virtio-blk)
#   - reads/writes on a host directory shared over virtiofs
# Env: GB per step (4).
. "$(dirname "$0")/common.sh"
GB=${GB:-4}
SHARED=$(cd "$(dirname "$0")" && pwd)/io-paths.tmp   # under $HOME, so colima shares it
start_vm "$1" "${2:-stock}" 4 3
docker --context "$CTX" pull -q alpine >/dev/null 2>&1
docker --context "$CTX" rm -f sink >/dev/null 2>&1
docker --context "$CTX" run -d --name sink alpine sleep 3600 >/dev/null
sleep 10; measure idle

dd if=/dev/zero bs=1M count=$((GB * 1024)) 2>/dev/null \
  | docker --context "$CTX" exec -i sink sh -c 'cat > /dev/null'
sleep 5; measure "${GB} GB via docker exec -i"

docker --context "$CTX" exec sink sh -c "dd if=/dev/urandom of=/big bs=1M count=$((GB * 1024)) 2>/dev/null; sync; rm /big; sync"
sleep 5; measure "${GB} GB written to disk"

mkdir -p "$SHARED"
guest "dd if=/dev/urandom of=$SHARED/f bs=1M count=2048 conv=fsync"; sleep 5; measure "2 GB written via virtiofs"
guest "sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; cat $SHARED/f > /dev/null"; sleep 5; measure "2 GB read via virtiofs"
guest "sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'"; sleep 30; measure "+30 s after drop_caches"

docker --context "$CTX" rm -f sink >/dev/null 2>&1
stop_vm; rm -rf "$SHARED"
