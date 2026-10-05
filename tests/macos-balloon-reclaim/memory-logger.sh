#!/bin/bash
# Usage: memory-logger.sh [profile]   (default profile: krun)
#
# Long-running logger for a real workday: every 5 min appends one CSV line with
# krunkit's phys_footprint and own regions, the guest's view, and host memory.
# Run it in the background: nohup ./memory-logger.sh >/dev/null 2>&1 &
# Exits after 1 h without a krunkit process.
# Env: OUT (memory-log.csv next to this script), INTERVAL seconds (300).
PROFILE=${1:-krun}
OUT=${OUT:-$(cd "$(dirname "$0")" && pwd)/memory-log.csv}
INTERVAL=${INTERVAL:-300}
[ -s "$OUT" ] || echo "time,pid,phys_mb,regions_mb,guest_used_mb,guest_cache_mb,guest_free_mb,host_free_mb,host_compressor_mb" > "$OUT"
missing=0
while :; do
  PID=$(pgrep -x krunkit | head -1)
  if [ -z "$PID" ]; then
    missing=$((missing + 1)); [ $((missing * INTERVAL)) -ge 3600 ] && exit 0
    sleep "$INTERVAL"; continue
  fi
  missing=0
  read -r phys reg < <(footprint -p "$PID" -f bytes 2>/dev/null | awk '
    /phys_footprint:/{p=$2} /Footprint:/{for(i=1;i<=NF;i++) if($i=="Footprint:") r=$(i+1)}
    END{print int(p/1048576), int(r/1048576)}')
  read -r gu gc gf < <(colima ssh -p "$PROFILE" -- free -m </dev/null 2>/dev/null | awk '/^Mem:/{print $3, $6, $4}')
  read -r hf hc < <(vm_stat | awk -F: '
    /Pages free/{gsub(/[ .]/,"",$2); f=$2} /Pages stored in compressor/{gsub(/[ .]/,"",$2); c=$2}
    END{print int(f*16384/1048576), int(c*16384/1048576)}')
  echo "$(date '+%F %H:%M'),$PID,$phys,$reg,$gu,$gc,$gf,$hf,$hc" >> "$OUT"
  sleep "$INTERVAL"
done
