// jitprobe —— 在 iOS 上直接测三件事，输出一行行结果
//   1) 自己的 csflags 里有没有 CS_DEBUGGED（0x1000000 部分）  ← 验证 jbctl proc_set_debugged 是否生效
//   2) 普通 mmap(PROT_READ|PROT_WRITE|PROT_EXEC) 能不能成功   ← V8 早期就是这么拿代码页的
//   3) MAP_JIT 映射 + mprotect(PROT_EXEC) + 写一字节          ← Apple 硅上的 JIT 标准姿势
//
// 编译（CI）:
//   clang -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 -o jitprobe jitprobe.c
// 用法: jitprobe            （直接跑）
//       dsh-jitlaunch jitprobe   （经启动器跑，对比 CS_DEBUGGED）

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

// CS_OPS_STATUS = 0, CS_DEBUGGED = 0x10000000
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#define CS_DEBUGGED 0x10000000
#define CS_HARD 0x00000100
#define CS_RESTRICT 0x00000800
#define CS_REQUIRE_LV 0x00002000

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

int main(void) {
    printf("pid=%d\n", (int)getpid());

    unsigned int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
        printf("csflags=0x%08x debugged=%d hard=%d restrict=%d require_lv=%d\n",
               flags, (flags & CS_DEBUGGED) ? 1 : 0, (flags & CS_HARD) ? 1 : 0,
               (flags & CS_RESTRICT) ? 1 : 0, (flags & CS_REQUIRE_LV) ? 1 : 0);
    } else {
        printf("csops 失败: %s\n", strerror(errno));
    }

    // 1) 直接要 RWX
    void *p1 = mmap(NULL, 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
                    MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p1 == MAP_FAILED) {
        printf("rwx_mmap=FAIL errno=%d(%s)\n", errno, strerror(errno));
    } else {
        memset(p1, 0xc3, 16); // ret sled
        printf("rwx_mmap=OK\n");
    }

    // 2) MAP_JIT + mprotect
    void *p2 = mmap(NULL, 65536, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p2 == MAP_FAILED) {
        printf("mapjit=FAIL errno=%d(%s)\n", errno, strerror(errno));
    } else {
        int rc = mprotect(p2, 65536, PROT_READ | PROT_EXEC);
        printf("mapjit=OK mprotect_exec=%s\n", rc == 0 ? "OK" : strerror(errno));
        if (rc == 0) {
            // 重新开写权限试写，模拟 JIT 写代码
            void *p3 = mmap(p2, 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
                            MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_JIT, -1, 0);
            printf("mapjit_rwx=%s\n", p3 == MAP_FAILED ? strerror(errno) : "OK");
        }
    }
    return 0;
}
