#!/bin/bash
# Usage: reclaim-cycles.sh <libkrun_dir> [reclaim]
#
# Main test. Four guest processes fill most of the guest RAM at the same time
# (tmpfs), then free it; repeat. After each cycle the guest drops its page cache
# and compacts memory so free-page reporting sees 2 MB blocks.
#
# Expected with the patch: phys_footprint goes back near the idle value every cycle.
# Expected with stock libkrun: phys_footprint stays at roughly the guest RAM size.
# A leak would show as phys_footprint growing cycle after cycle, or exceeding the
# guest RAM size plus krunkit's fixed overhead.
#
# Env: CYCLES (8), CPUS (4), MEM_GB (3), FILL_MB per process (600).
. "$(dirname "$0")/common.sh"
CYCLES=${CYCLES:-8}; FILL_MB=${FILL_MB:-600}
start_vm "$1" "${2:-stock}" "${CPUS:-4}" "${MEM_GB:-3}"
docker --context "$CTX" pull -q alpine >/dev/null 2>&1; sleep 10
measure idle; host_line idle
for c in $(seq "$CYCLES"); do
  docker --context "$CTX" run --rm \
    --mount type=tmpfs,destination=/m,tmpfs-size=$((FILL_MB * 4 + 200))m alpine sh -c "
      for i in 1 2 3 4; do dd if=/dev/urandom of=/m/f\$i bs=1M count=$FILL_MB 2>/dev/null & done; wait" \
    >/dev/null 2>&1
  drop_and_compact; sleep 15
  measure "cycle $c"
done
host_line end
stop_vm
