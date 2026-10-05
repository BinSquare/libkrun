# Balloon reclaim tests (macOS, krunkit)

Scripts used to validate `KRUN_BALLOON_RECLAIM` on macOS. Each test boots a
throwaway [Colima](https://github.com/abiosoft/colima) profile (`kt` by default,
override with `PROFILE=`) with `--vm-type krunkit`, loading the libkrun build you
point it at, so the patched and the stock library can be run on the same workload.

These are manual, host-side scripts for macOS; they are not part of the
`tests/run.sh` runner.

Requirements: macOS on Apple silicon, `colima`, `krunkit`, `docker` CLI, and a
libkrun 1.x build directory containing `libkrun.1.dylib` (krunkit 1.x links the
1.x ABI). Run each test twice, e.g.:

    ./reclaim-cycles.sh /path/to/patched-libkrun reclaim
    ./reclaim-cycles.sh /path/to/stock-libkrun

## What is measured

- `phys_footprint`: what macOS charges krunkit (Activity Monitor's "Memory" column).
  It counts compressed pages at their uncompressed size.
- `regions`: dirty memory in krunkit's own mapped regions. Guest RAM is mostly not
  in here, so this isolates host-side allocations.
- the guest's own `free -m` (used + page cache), and host-wide `vm_stat`.

Free-page reporting only reports free blocks of 2 MB (order 9), so the tests drop
the guest page cache and run `compact_memory` before measuring.

## Tests

| Script | What it checks |
|---|---|
| `reclaim-cycles.sh` | Main test. 4 guest processes fill most of the guest RAM and free it, repeatedly. With the patch phys_footprint returns near idle every cycle; with stock libkrun it stays at the guest RAM size. Growth across cycles would mean a leak. |
| `integrity-under-pressure.sh` | Freed memory is taken back by macOS under host memory pressure, and live guest data (tmpfs and disk) keeps the same sha256 after reclaim and refault. |
| `parallel-stress.sh` | 4 vCPUs refaulting reclaimed ranges concurrently while the host keeps reclaiming; hash mismatches would mean corruption, duration shows the refault cost. |
| `io-paths.sh` | Diagnostic: which I/O paths grow krunkit's own memory (Docker socket stream, virtio-blk writes, virtiofs). |
| `madvise-control.py` | Positive/negative control for the measurement itself: `MADV_FREE_REUSABLE` vs `munmap` on a plain process. |
| `memory-logger.sh` | Logs krunkit and host memory every 5 min to a CSV during real use. |
| `guest/` | `trim-page-cache` + systemd timer for the guest: keeps the page cache at ~1 GB and compacts memory every 2 minutes, so freed memory actually gets reported. |

## Results (Mac with 24 GB, libkrun 1.19.4, krunkit 1.3.2, Colima, Ubuntu 24.04 guest kernel 6.8)

`reclaim-cycles.sh`, 3 GiB / 4 vCPU guest, 4 x 600 MB filled and freed per cycle:

| after 8 cycles | patched + `KRUN_BALLOON_RECLAIM=1` | stock |
|---|---|---|
| krunkit phys_footprint | 1.3 GB (idle: 1.2 GB) | 3.7 GB |
| krunkit regions | 0.5 GB | 0.6 GB |

- `integrity-under-pressure.sh`: hashes match; host free memory +1.3–1.5 GB after
  the guest frees 1.5 GB (stock: no change).
- `parallel-stress.sh`: 48/48 cycles without mismatches, no measurable slowdown.
- `io-paths.sh`: the Docker socket stream and virtio-blk writes add little (~150 MB
  and ~40 MB for 8 GB). virtiofs does not: writing 2 GB through a shared directory
  grew krunkit from 1.2 to 5.3 GB on a 3 GB guest, released once the guest dropped
  its page cache.

Open: on an 8 GB guest in daily use (VS Code dev container), krunkit stays several
GB above what the guest uses, mostly compressed by macOS. Still being measured with
`memory-logger.sh`.
