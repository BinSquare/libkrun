# Shared helpers for the balloon reclaim tests. Source it, don't run it.
#
# Every test boots a throwaway Colima profile (krunkit) with a given libkrun build,
# so the patched and the stock library can be compared on the same workload:
#
#   start_vm <libkrun_dir> <reclaim|stock> [cpus] [mem_gb]
#
# <libkrun_dir> holds libkrun.1.dylib and is put first in DYLD_LIBRARY_PATH.
# "reclaim" sets KRUN_BALLOON_RECLAIM=1 (the patch is opt-in).
#
# What is measured, per krunkit process:
#   phys_footprint  what macOS charges the process (Activity Monitor "Memory")
#   regions         dirty memory in krunkit's own mapped regions (not guest RAM)
# plus the guest's own view (free -m: used + page cache).

PROFILE=${PROFILE:-kt}
CTX=colima-$PROFILE

start_vm() {
  local lib=$1 mode=$2 cpus=${3:-2} mem=${4:-3} before
  export DYLD_LIBRARY_PATH="$lib"
  if [ "$mode" = reclaim ]; then export KRUN_BALLOON_RECLAIM=1; else unset KRUN_BALLOON_RECLAIM; fi
  # Other krunkit VMs may be running; the new one is the PID that wasn't there before.
  before=$(pgrep -x krunkit)
  colima start -p "$PROFILE" --vm-type krunkit --cpu "$cpus" --memory "$mem" --disk 20 \
    --activate=false >"/tmp/$PROFILE-start.log" 2>&1 \
    || { echo "colima start failed:"; tail -20 "/tmp/$PROFILE-start.log"; exit 1; }
  PID=$(pgrep -x krunkit | grep -vxF "$before" | head -1)
  [ -n "$PID" ] || { echo "could not find the new krunkit PID"; exit 1; }
  echo "=== libkrun=$(basename "$lib")  $(ps eww -p "$PID" | grep -o 'KRUN_BALLOON_RECLAIM=[^ ]*' || echo reclaim=off)  pid=$PID  ${cpus} vCPU  ${mem} GiB"
}

stop_vm() { colima stop -p "$PROFILE" >/dev/null 2>&1; }

# colima ssh reads stdin; keep it away from whatever pipe the caller is in.
guest() { colima ssh -p "$PROFILE" -- sh -c "$1" </dev/null 2>/dev/null; }

measure() {
  local g
  g=$(guest 'free -m' | awk '/^Mem:/{print $3"+"$6}')
  footprint -p "$PID" -f bytes 2>/dev/null | awk -v l="$1" -v g="$g" '
    /phys_footprint:/{p=$2}
    /Footprint:/{for(i=1;i<=NF;i++) if($i=="Footprint:") r=$(i+1)}
    END{printf "  %-30s phys_footprint=%5d MB  regions=%5d MB  guest(used+cache)=%s MB\n", l, p/1048576, r/1048576, g}'
}

# Host-wide view, independent of how krunkit's footprint is accounted.
host_line() {
  vm_stat | awk -v l="$1" -F: '
    /Pages free/{gsub(/[ .]/,"",$2); f=$2}
    /Pages stored in compressor/{gsub(/[ .]/,"",$2); c=$2}
    END{printf "  %-30s host free=%5d MB  compressor=%6d MB  reusable=%5d MB\n", l, f*16384/1048576, c*16384/1048576, r}' \
    r="$(( $(sysctl -n vm.page_reusable_count) * 16384 / 1048576 ))"
}

drop_and_compact() { guest 'sudo sh -c "sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory"'; }
