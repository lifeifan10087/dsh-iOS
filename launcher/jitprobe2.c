// jitprobe2 —— 真正测「能不能在内存里生成并执行代码」
// arm64 机器码: mov w0, #42 ; ret
//   mov w0,#42 -> 0x52800540  （小端字节 40 05 80 52）
//   ret        -> 0xD65F03C0  （小端字节 C0 03 5F D6）
// 用法: jitprobe2 | dsh-jitlaunch jitprobe2
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static const unsigned char kCode[] = {0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6};

typedef int (*fn_t)(void);

static void report(const char *name, int ok, int err) {
    if (ok) printf("%s=OK\n", name);
    else printf("%s=FAIL errno=%d(%s)\n", name, err, strerror(err));
}

int main(void) {
    unsigned int flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) == 0)
        printf("csflags=0x%08x debugged=%d hard=%d\n", flags,
               (flags & 0x10000000) ? 1 : 0, (flags & 0x00000100) ? 1 : 0);

    // A: 直接 mmap RWX 并执行
    {
        void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { report("A_mmap_rwx", 0, errno); }
        else {
            memcpy(p, kCode, sizeof(kCode));
            __builtin___clear_cache((char *)p, (char *)p + sizeof(kCode));
            int v = ((fn_t)p)();
            printf("A_mmap_rwx_exec=%s (ret=%d)\n", v == 42 ? "OK" : "WRONG", v);
        }
    }

    // B: mmap RW → mprotect RX → 执行（V8 无 MAP_JIT 时的路径）
    {
        void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { report("B_mmap_rw", 0, errno); }
        else {
            memcpy(p, kCode, sizeof(kCode));
            if (mprotect(p, 16384, PROT_READ | PROT_EXEC) != 0) report("B_mprotect_rx", 0, errno);
            else {
                __builtin___clear_cache((char *)p, (char *)p + sizeof(kCode));
                int v = ((fn_t)p)();
                printf("B_rx_exec=%s (ret=%d)\n", v == 42 ? "OK" : "WRONG", v);
            }
        }
    }

    // C: mprotect 在 RW↔RX 之间来回切（mprotect 版 W^X）
    {
        void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            memcpy(p, kCode, sizeof(kCode));
            int r1 = mprotect(p, 16384, PROT_READ | PROT_EXEC);
            int r2 = mprotect(p, 16384, PROT_READ | PROT_WRITE);
            unsigned char patch[4] = {0x40, 0x05, 0x80, 0x52}; // 再写一遍 mov
            if (r2 == 0) memcpy(p, patch, 4);
            int r3 = mprotect(p, 16384, PROT_READ | PROT_EXEC);
            printf("C_rx=%s rw=%s rx_again=%s\n",
                   r1 == 0 ? "OK" : "FAIL", r2 == 0 ? "OK" : "FAIL", r3 == 0 ? "OK" : "FAIL");
            if (r3 == 0) {
                __builtin___clear_cache((char *)p, (char *)p + sizeof(kCode));
                int v = ((fn_t)p)();
                printf("C_exec=%s (ret=%d)\n", v == 42 ? "OK" : "WRONG", v);
            }
        }
    }

    // D: MAP_JIT（预期在 iOS 上 EINVAL）
    {
        void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON | 0x0800, -1, 0);
        report("D_map_jit", p != MAP_FAILED, errno);
    }
    return 0;
}
