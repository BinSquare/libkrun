#!/usr/bin/env bash
# Cost of balloon-reclaim refaults.
#
# After the guest frees memory, the host unmaps the reported ranges from
# stage-2; the next guest touch of such a range faults out to be remapped.
# Time the SAME re-touch with KRUN_BALLOON_RECLAIM=1 and without, and compare.
#
# Supply a way to run a shell command inside the already-booted guest, e.g.
#   GUEST_EXEC='ssh guest sh -c'         ./refault-bench.sh 3 "reclaim ON"
#   GUEST_EXEC='myvmm exec --name vm --' ./refault-bench.sh 3 "reclaim OFF"
#
# usage: GUEST_EXEC='<cmd>' ./refault-bench.sh <GB> <label>
set -u
: "${GUEST_EXEC:?set GUEST_EXEC to a command that runs 'sh -c <script>' in the guest}"
GB="${1:-3}"; LABEL="${2:-run}"; MB=$((GB * 1024))

guest() { $GUEST_EXEC "$1" >/dev/null 2>&1; }

phase() {
  local desc="$1" script="$2" t0 t1
  t0=$(python3 -c 'import time; print(time.time())')
  guest "$script"
  t1=$(python3 -c 'import time; print(time.time())')
  printf "  %-36s %6.2fs\n" "$desc" "$(python3 -c "print($t1-$t0)")"
}

echo "== $LABEL =="
# 1. cold fill -- fresh guest pages, nothing reclaimed yet: the baseline
phase "fill ${GB}G (cold, no reclaim yet)" \
      "dd if=/dev/zero of=/dev/shm/b bs=1M count=$MB; sync"

# 2. free -- the guest reports the pages; with reclaim on the host unmaps them
guest 'rm -f /dev/shm/b; sync'
sleep 20   # let free-page reporting drain

# 3. refill -- with reclaim on, each first touch of a reclaimed range faults out
phase "refill ${GB}G (refaults if reclaimed)" \
      "dd if=/dev/zero of=/dev/shm/b bs=1M count=$MB; sync"

# 4. rewrite -- pages are mapped again, so this is steady state; it separates
#    the one-off refault cost from ordinary write throughput
phase "rewrite ${GB}G (already mapped)" \
      "dd if=/dev/zero of=/dev/shm/b bs=1M count=$MB conv=notrunc; sync"

guest 'rm -f /dev/shm/b; sync'

# Sanity: the ON arm is only meaningful if the ranges really were unmapped.
# Watch the host side across the same cycle --
#   vmmap --summary <vmm-pid> | grep 'Physical footprint:'
# -- and confirm it drops after step 2 and climbs back during step 3.
