#!/usr/bin/env python3
"""Positive/negative control for measuring freed memory on macOS.

Usage: madvise-control.py <none|reusable|munmap>

Touches 800 MB of anonymous memory, then either keeps it (none), marks it
MADV_FREE_REUSABLE (reusable) or unmaps it (munmap), and prints the process
footprint and the kernel's dirty/swapped view of its VM objects.

It shows why MADV_FREE_REUSABLE alone is not enough: footprint drops, but the
pages stay dirty in their VM object until something reuses them, whereas munmap
(or replacing the mapping) frees them for real.
"""
import mmap
import os
import subprocess
import sys
import time

mode = sys.argv[1]
N = 800 * 1024 * 1024
pid = str(os.getpid())


def measure(label):
    fp = subprocess.run(["footprint", "-p", pid], capture_output=True, text=True).stdout
    f = [l for l in fp.splitlines() if "Footprint:" in l]
    vo = subprocess.run(["footprint", "-w", "--vmObjectDirty", "-p", pid],
                        capture_output=True, text=True).stdout
    t = [l.split() for l in vo.splitlines() if l.strip().endswith("TOTAL")]
    foot = f[0].split("Footprint:")[1].split("(")[0].strip() if f else "?"
    dirty = t[0][0] + t[0][1] if t else "?"
    swapped = t[0][2] + t[0][3] if t else "?"
    print(f"  {mode:9s} {label:10s} footprint={foot:>8}   vm objects: dirty={dirty} swapped={swapped}",
          flush=True)


m = mmap.mmap(-1, N)
for i in range(0, N, 16384):
    m[i] = 1
time.sleep(2)
measure("touched")
if mode == "reusable":
    m.madvise(7)  # MADV_FREE_REUSABLE on Darwin
elif mode == "munmap":
    m.close()
time.sleep(5)
measure("+5 s")
time.sleep(15)
measure("+20 s")
