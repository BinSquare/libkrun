#!/bin/bash
# Usage: integrity-under-pressure.sh <libkrun_dir> [reclaim]
#
# 1. Leave ~1.5 GB of freed (reported) memory behind in the guest.
# 2. Write random data in the guest, in RAM (tmpfs) and on disk, and hash it.
# 3. Put the host under memory pressure (touch free + 1.5 GB and hold it 40 s).
# 4. Re-read both with the guest page cache dropped and compare hashes.
#
# Checks two things: whether macOS can take back krunkit's freed pages under
# pressure, and that live guest data survives reclaim + refault untouched.
. "$(dirname "$0")/common.sh"
start_vm "$1" "${2:-stock}" 2 3
docker --context "$CTX" pull -q alpine >/dev/null 2>&1; sleep 10
measure idle; host_line idle

docker --context "$CTX" run -d --name peak --mount type=tmpfs,destination=/m,tmpfs-size=1800m alpine \
  sh -c 'dd if=/dev/zero of=/m/x bs=1M count=1500 2>/dev/null; sleep 600' >/dev/null
sleep 25; measure "1.5 GB in use"
docker --context "$CTX" rm -f peak >/dev/null 2>&1; sleep 30; measure "1.5 GB freed"; host_line "1.5 GB freed"

guest 'sudo sh -c "mkdir -p /run/data && mount -t tmpfs -o size=700m tmpfs /run/data;
  dd if=/dev/urandom of=/run/data/r bs=1M count=600 2>/dev/null;
  dd if=/dev/urandom of=/var/tmp/disk bs=1M count=300 2>/dev/null; sync"' >/dev/null
H1=$(guest 'sha256sum /run/data/r /var/tmp/disk | cut -c1-16 | tr "\n" " "')
sleep 10; measure "data written"

free_mb=$(vm_stat | awk -F: '/Pages free/{gsub(/[ .]/,"",$2); print int($2*16384/1048576)}')
echo "  host pressure: touching $((free_mb + 1500)) MB for 40 s"
python3 -c '
import mmap, sys, time
n = int(sys.argv[1]) * 1024 * 1024
m = mmap.mmap(-1, n)
for i in range(0, n, 16384):
    m[i] = 1
time.sleep(40)' $((free_mb + 1500)) &
sleep 20; measure "pressure +20 s"; host_line "pressure +20 s"
wait; sleep 10; measure "pressure released"

guest 'sudo sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"'
H2=$(guest 'sha256sum /run/data/r /var/tmp/disk | cut -c1-16 | tr "\n" " "')
echo "  sha256 before: $H1"
echo "  sha256 after : $H2"
[ -n "$H1" ] && [ "$H1" = "$H2" ] && echo "  INTEGRITY: OK" || echo "  INTEGRITY: FAILED"
echo "  suspicious guest dmesg lines: $(guest 'sudo dmesg | grep -ciE "bug|oops|corrupt|segfault|panic"')"
echo "  krunkit alive: $(kill -0 "$PID" 2>/dev/null && echo yes || echo NO)"
stop_vm
