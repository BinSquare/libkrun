// Does MADV_FREE (upstream libkrun's macOS balloon path) actually return pages
// to the host, or only MADV_FREE_REUSABLE (what PR #794 switches to)?
// Touch a large anonymous mapping, madvise it, report phys_footprint each step.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/task.h>

static long long footprint_mb(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return -1;
    return (long long)(info.phys_footprint / (1024 * 1024));
}

int main(int argc, char **argv) {
    size_t mb = (argc > 1) ? (size_t)atoi(argv[1]) : 1536;
    int advice = (argc > 2 && strcmp(argv[2], "reusable") == 0) ? MADV_FREE_REUSABLE : MADV_FREE;
    const char *name = (advice == MADV_FREE_REUSABLE) ? "MADV_FREE_REUSABLE" : "MADV_FREE";
    size_t len = mb * 1024 * 1024;

    printf("  baseline footprint: %lld MB\n", footprint_mb());
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    memset(p, 1, len);                       // fault every page in
    printf("  after touching %zu MB: %lld MB\n", mb, footprint_mb());

    int r = madvise(p, len, advice);
    printf("  madvise(%s) -> %d%s\n", name, r, r ? " (errno set)" : "");
    printf("  after madvise:      %lld MB\n", footprint_mb());
    return 0;
}
