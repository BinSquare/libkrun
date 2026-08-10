// Rank every process on the machine by ri_phys_footprint -- the kernel's own
// accounting, and the exact quantity memorystatus/jetsam uses to choose a
// victim within a priority band. No root, no private command numbers: just
// proc_listpids + proc_pid_rusage, both supported.
//
// build: clang -O2 -o footrank footrank.c
// run:   ./footrank [pid_to_highlight ...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/types.h>

struct row { pid_t pid; long long mb; char name[2 * MAXCOMLEN + 2]; };

static int cmp(const void *a, const void *b) {
    const struct row *x = a, *y = b;
    return (y->mb > x->mb) - (y->mb < x->mb);
}

int main(int argc, char **argv) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    pid_t *pids = calloc(n, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n * sizeof(pid_t)) / sizeof(pid_t);

    struct row *rows = calloc(n, sizeof(struct row));
    int m = 0;
    for (int i = 0; i < n; i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v2 ri;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0) continue;
        rows[m].pid = pids[i];
        rows[m].mb = (long long)(ri.ri_phys_footprint / (1024 * 1024));
        proc_name(pids[i], rows[m].name, sizeof(rows[m].name));
        m++;
    }
    qsort(rows, m, sizeof(*rows), cmp);

    printf("%-5s %-8s %-12s %s\n", "rank", "pid", "footprintMB", "name");
    for (int i = 0; i < m && i < 20; i++) {
        int hit = 0;
        for (int a = 1; a < argc; a++) if (rows[i].pid == (pid_t)atoi(argv[a])) hit = 1;
        printf("%-5d %-8d %-12lld %s%s\n", i + 1, rows[i].pid, rows[i].mb, rows[i].name,
               hit ? "   <=== TARGET" : "");
    }
    // Always report the targets' ranks even if outside the top 20.
    for (int a = 1; a < argc; a++) {
        pid_t want = (pid_t)atoi(argv[a]);
        for (int i = 0; i < m; i++) {
            if (rows[i].pid == want) {
                printf("target pid %d: rank %d of %d, %lld MB (%s)\n",
                       want, i + 1, m, rows[i].mb, rows[i].name);
                break;
            }
        }
    }
    return 0;
}
