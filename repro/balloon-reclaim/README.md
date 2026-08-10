# Reproducing the macOS balloon-reclaim measurements

Self-contained measurements for the HVF balloon free-page reclaim change. Two
small C programs and a shell script; no root, no induced memory pressure, and
nothing specific to any one VMM — the feature is gated by `KRUN_BALLOON_RECLAIM=1`,
so both arms are the same binary.

All numbers below were taken on macOS 26.1, Apple Silicon, 36 GB.

```sh
cc -O2 -o footrank footrank.c
cc -O2 -o madv     madv.c
```

## 1. Is `MADV_FREE` enough on its own?

`madv` mmaps N MB, touches every page, madvises the range, and prints
`phys_footprint` (via `task_info(TASK_VM_INFO)`) at each step.

```sh
./madv 1536 free        # what the balloon path used before this change
./madv 1536 reusable    # what it uses now
```

```
MADV_FREE           1537 MB -> 1537 MB    (returns 0, changes nothing)
MADV_FREE_REUSABLE  1537 MB ->    1 MB
```

So on ordinary anonymous memory the advice change alone is sufficient. On
`hv_vm_map`'d guest RAM it is **not** — see the control arm in §2, where
`MADV_FREE_REUSABLE` is compiled in and the footprint still does not move.
That is the case for unmapping from stage-2 rather than only re-advising.

## 2. Footprint held after the guest frees

Boot an 8 GB guest twice, once with `KRUN_BALLOON_RECLAIM=1` and once without.
In the guest, each time:

```sh
dd if=/dev/urandom of=/dev/shm/blob bs=1M count=5120; sync
sleep 2
rm -f /dev/shm/blob; sync          # guest frees and reports the pages
```

Wait ~20s for free-page reporting to drain, then on the host:

```sh
vmmap --summary <vmm-pid> | grep 'Physical footprint:'
```

| guest fill | reclaim off | reclaim on |
|---|---|---|
| 6 GB of zeros | **4.2 G**, still 4.2 G after 90 s | **301.5 M** |
| 5 GB from `/dev/urandom` | **4.2 G** | **300.3 M** |

## 3. Where that leaves the process in the kill order

`phys_footprint` is what memorystatus compares when choosing a victim within a
priority band. `footrank` reads the kernel's own value for every process
(`proc_pid_rusage`, `RUSAGE_INFO_V2`) and sorts by it — that ordering is the
kill order.

```sh
./footrank <vmm-pid-reclaim-off> <vmm-pid-reclaim-on>
```

Two identical 8 GB guests, same workload as §2, both idle when measured:

```
rank  pid      footprintMB  name
1     31305    4282         <vmm>          <-- reclaim OFF
2     59925    3975         browser GPU helper
3     48021    3539         another long-running VM (unrelated, 3 weeks up)
...
target reclaim OFF: rank  1 of 438, 4282 MB
target reclaim ON:  rank 44 of 438,  300 MB
```

Without the change the VMM is the largest process on the machine — ahead of the
browser's GPU helper — for memory the guest has already returned. With it, rank
44 of 438.

This is the distinction worth drawing: system-wide pressure **does** recover
without this change (measured below), and the process is **still** ranked at the
top of the kill order. Recovery concerns memorystatus's trigger; ranking
concerns its target. Only the second is what this change affects, and it is what
decides which process is chosen once pressure does arrive.

## 4. System pressure, for completeness

`kern.memorystatus_level` sampled across the same allocate/free cycle (8 GB
guest, 6 GB):

| | baseline -> allocated -> freed |
|---|---|
| reclaim off | 56 -> 53 -> **55** |
| reclaim on | 55 -> 53 -> **53** |

Single samples on a busy desktop, differing by less than the run-to-run noise.
**This is not evidence that the change improves system-wide pressure**, and it
is consistent with the view that `MADV_FREE` already returns the pages to the
system. The demonstrated effect is on per-process accounting only.

## 5. Refault cost

Every first touch of a reclaimed range faults out to be remapped. `refault-bench.sh`
times fill / free / refill / rewrite. 8 GB guest, 3 GB:

| phase | reclaim off | reclaim on |
|---|---|---|
| fill 3G (cold, nothing reclaimed yet) | 0.83s | 0.83s |
| **refill 3G (refaults here)** | **0.93s** | **0.83s** |
| rewrite 3G (already mapped) | 0.83s | 0.60s |

Confirmed the reclaim was actually engaged rather than merely enabled, so those
writes really did fault and remap:

```
after fill 3G:      1.6G
after free (unmap): 309.3M
after refill:       2.5G  in 0.82s
```

Reclaim unmaps and remaps a whole *reported range*, and the guest reports in
>= 4 MiB multiples, so re-touching 3 GB costs on the order of <= 768 exits — one
`hv_vm_map` each, single-digit milliseconds against a 0.8 s workload. The cost is
per-range, not per-page.

**Not measured:** many small scattered ranges (more exits per byte re-touched),
and multi-vCPU contention — the refault path takes a global mutex, so several
vCPUs faulting at once serialize.

## 6. On an actual jetsam kill

Not reproduced. For completeness, what was tried and failed on macOS 26.1:

| approach | outcome |
|---|---|
| `memorystatus_control` fatal memlimit, as root | returned 0, limit not enforced; command numbers are unverified, so this result is inconclusive |
| launchd user agent `JetsamProperties/JetsamMemoryLimit` | ignored: `Ignoring jetsam update because this process is not memory-managed` |
| `.app` bundle via LaunchServices | no RunningBoard jetsam management observed |
| global pressure, 26 GB compressible | level 56 -> 48, nothing killed |
| global pressure, incompressible | 2 GB moved the level 0 points; reaching a kill means exhausting free RAM and forcing heavy swap, endangering every process on the machine |

So this does not demonstrate a kill; it demonstrates the ranking that a kill
would select from. If kills are being observed in a bundled, RunningBoard-managed
app, the reproducer for that has to come from that context — it does not appear
to be constructible from a terminal.

## Two traps that silently invalidate results

- **A constant fill compresses to nothing.** `memset`-filled or `/dev/zero`
  pages are squashed by the compressor, cost little real memory, and generate no
  pressure. Use `/dev/urandom` or a PRNG for anything measuring pressure. An
  early attempt here held "26 GB" that cost almost nothing.
- **Check the flag on the VMM process, not the shell**
  (`ps -E -p <pid> | tr ' ' '\n' | grep BALLOON_RECLAIM`). The harness used here
  enabled reclaim by default, so the intended control arm was silently identical
  to the test arm — an A/A comparison that returned clean, agreeing numbers and
  nearly read as "the feature does nothing".
