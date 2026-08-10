// Incremental host memory pressure generator for the Jetsam reproducer.
// Allocates and TOUCHES memory in 512 MB steps until either the cap is hit or
// kern.memorystatus_level falls below the floor, then holds. Self-limiting so
// the machine is never driven further than the experiment requires.
//
// build: clang -O2 -o hog hog.c
// run:   ./hog <cap_GB> <level_floor>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

static int mem_level(void) {
    int level = -1;
    size_t len = sizeof(level);
    if (sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0) != 0) return -1;
    return level;
}

int main(int argc, char **argv) {
    int cap_gb = (argc > 1) ? atoi(argv[1]) : 16;
    int floor  = (argc > 2) ? atoi(argv[2]) : 12;
    const size_t STEP = 512UL * 1024 * 1024;
    size_t steps = ((size_t)cap_gb * 1024UL * 1024 * 1024) / STEP;

    fprintf(stderr, "hog: cap=%d GB floor=level<%d start_level=%d\n", cap_gb, floor, mem_level());
    for (size_t i = 0; i < steps; i++) {
        char *p = mmap(NULL, STEP, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { fprintf(stderr, "hog: mmap failed at %zu MB\n", i * 512); break; }
        // Fill with INCOMPRESSIBLE data. A constant fill (memset) is squashed
        // by macOS's WKdm compressor to almost nothing, so the pages cost no
        // real RAM and pressure never rises -- the first version of this
        // reproducer failed for exactly that reason.
        {
            unsigned long long x = 0x9E3779B97F4A7C15ULL ^ (unsigned long long)i;
            unsigned long long *q = (unsigned long long *)p;
            for (size_t k = 0; k < STEP / sizeof(*q); k++) {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17;   // xorshift64
                q[k] = x;
            }
        }
        int lv = mem_level();
        fprintf(stderr, "hog: held=%zu MB level=%d\n", (i + 1) * 512, lv);
        fflush(stderr);
        if (lv >= 0 && lv < floor) {
            fprintf(stderr, "hog: level floor reached, holding\n");
            break;
        }
        usleep(300000);
    }
    fprintf(stderr, "hog: holding pressure; kill me to release\n");
    for (;;) pause();
    return 0;
}
