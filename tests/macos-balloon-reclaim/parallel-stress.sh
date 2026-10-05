#!/bin/bash
# Usage: parallel-stress.sh <libkrun_dir> [reclaim]
#
# 4 vCPU. Four guest workers loop: write 250 MB of random data to tmpfs, hash it,
# wait, hash it again, delete it. Meanwhile the host keeps reclaiming what the
# guest reports free, so vCPUs keep refaulting reclaimed ranges concurrently.
# Any hash mismatch means corruption. Total time shows the refault cost.
. "$(dirname "$0")/common.sh"
start_vm "$1" "${2:-stock}" 4 3
docker --context "$CTX" pull -q alpine >/dev/null 2>&1; sleep 10
measure idle
T0=$(date +%s)
docker --context "$CTX" run --rm --mount type=tmpfs,destination=/m,tmpfs-size=1400m alpine sh -c '
  w() { i=0; bad=0
    while [ $i -lt 12 ]; do
      dd if=/dev/urandom of=/m/f$1 bs=1M count=250 2>/dev/null
      a=$(sha256sum /m/f$1 | cut -c1-32); sleep 1
      b=$(sha256sum /m/f$1 | cut -c1-32)
      [ "$a" = "$b" ] || bad=$((bad+1))
      rm -f /m/f$1; sleep 2; i=$((i+1))
    done
    echo "worker $1: 12 cycles, mismatches=$bad"; }
  w 1 & w 2 & w 3 & w 4 & wait' 2>&1 | sed 's/^/  /' &
RUN=$!
while kill -0 $RUN 2>/dev/null; do sleep 15; measure "t=$(( $(date +%s) - T0 ))s"; done
wait $RUN
echo "  duration: $(( $(date +%s) - T0 ))s"
sleep 20; measure "+20 s"
echo "  krunkit alive: $(kill -0 "$PID" 2>/dev/null && echo yes || echo NO)"
echo "  guest dmesg: $(guest 'sudo dmesg' | grep -iE 'bug|oops|corrupt|segfault|panic' | tail -4 | tr '\n' '|')"
stop_vm
