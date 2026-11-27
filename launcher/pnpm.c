// pnpm —— 原生小启动器：把 pnpm 包装成 Mach-O
//
// 为什么不能是 shell 脚本：
//   · 这台设备上 /bin/sh 不存在（只有 /var/jb/bin/sh）
//   · 更要命的是 node 的 child_process.spawn 直接执行**脚本**会返回 EPERM
//     （iOS 的 posix_spawn 对 shebang 脚本限制），而 dsh 的插件管理用 execa →
//     spawn("pnpm") 必然失败。
// 所以这里编译成 Mach-O，内部 execv 到设备上的 node + pnpm.cjs。
//
// 编译（CI）：
//   clang -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 -o pnpm launcher/pnpm.c
// 安装：
//   /var/jb/usr/bin/pnpm  （dsh plugin 会按 PATH 找到它）

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define NODE "/var/jb/usr/local/lib/dsh/node"
#define PRELOAD "/var/mobile/Library/dsh/shim/ios-preload.cjs"
#define PNPM_CJS "/var/jb/usr/local/lib/dsh/pnpm/bin/pnpm.cjs"

int main(int argc, char **argv) {
    // 组装：node --jitless --require <preload> <pnpm.cjs> <原参数...>
    int extra = 5; // node 自身 + 4 个固定参数
    char **args = calloc((size_t)argc + extra + 1, sizeof(char *));
    if (!args) { perror("calloc"); return 1; }
    int i = 0;
    args[i++] = NODE;
    args[i++] = "--jitless";
    args[i++] = "--require";
    args[i++] = PRELOAD;
    args[i++] = PNPM_CJS;
    for (int a = 1; a < argc; a++) args[i++] = argv[a];
    args[i] = NULL;

    execv(NODE, args);
    perror("execv(" NODE ")");
    return 127;
}
