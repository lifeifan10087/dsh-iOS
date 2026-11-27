// dsh-jitlaunch —— 在越狱 iOS 上给 node 开 JIT 的极小启动器
//
// 背景：iOS 上 V8 要 JIT 必须有 CS_DEBUGGED（或 Apple 签名的 platform 二进制）。
// 越狱机的 jbctl 能打这个标志，但必须在进程**执行第一条指令之前**打上：
//   · 先 exec 再打 → 太晚，V8 初始化就 SIGBUS
//   · 给 shell 打上再 exec → exec 会清掉标志
// 所以这里用 POSIX_SPAWN_START_SUSPENDED 让子进程停在 exec 之后、入口点之前，
// 打标志，再 SIGCONT 放行。
//
// 用法（由 launchd 调用）：
//   dsh-jitlaunch /var/jb/usr/local/lib/dsh/node --expose-internals app.js web ...
//
// 编译（macOS + iPhoneOS SDK）：
//   clang -target arm64-apple-ios14.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
//         -O2 -Wall -o dsh-jitlaunch jitlaunch.c
// 签名（设备上）：ldid -S<entitlements.plist> dsh-jitlaunch

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef POSIX_SPAWN_START_SUSPENDED
#define POSIX_SPAWN_START_SUSPENDED 0x0080
#endif

extern char **environ;

static const char *JBCTL_PATHS[] = {
    "/var/jb/usr/bin/jbctl",
    "/var/jb/basebin/jbctl",
    "/usr/bin/jbctl",
    NULL,
};

static int run_set_debugged(pid_t pid) {
    for (int i = 0; JBCTL_PATHS[i]; i++) {
        if (access(JBCTL_PATHS[i], X_OK) != 0) continue;
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
                 "%s proc_set_debugged %d >/dev/null 2>&1", JBCTL_PATHS[i], (int)pid);
        int rc = system(cmd);
        if (rc == 0) return 0;
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: %s <可执行文件> [参数...]\n", argv[0]);
        return 2;
    }

    posix_spawnattr_t attr;
    int rc = posix_spawnattr_init(&attr);
    if (rc != 0) { fprintf(stderr, "spawnattr_init: %s\n", strerror(rc)); return 1; }

    sigset_t empty;
    sigemptyset(&empty);
    posix_spawnattr_setsigmask(&attr, &empty);
    sigset_t all;
    sigfillset(&all);
    posix_spawnattr_setsigdefault(&attr, &all);

    short flags = POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    rc = posix_spawnattr_setflags(&attr, flags);
    if (rc != 0) { fprintf(stderr, "spawnattr_setflags: %s\n", strerror(rc)); return 1; }

    // 子进程 stdout/stderr 继承 launchd 重定向好的日志文件
    pid_t pid = 0;
    rc = posix_spawn(&pid, argv[1], NULL, &attr, &argv[1], environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        fprintf(stderr, "posix_spawn(%s): %s\n", argv[1], strerror(rc));
        return 1;
    }

    // 子进程此刻停在 exec 之后、还没跑任何代码：现在打标志才有效
    if (run_set_debugged(pid) != 0)
        fprintf(stderr, "警告: jbctl proc_set_debugged %d 失败（JIT 可能不可用）\n", (int)pid);

    if (kill(pid, SIGCONT) != 0) perror("kill(SIGCONT)");

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) {
        fprintf(stderr, "子进程被信号 %d 终止\n", WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    return 0;
}
