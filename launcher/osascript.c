// iOS 上没有 AppleScript。这个 Mach-O 冒充 osascript，让 dsh 的目录选择能跑：
//   osascript -e 'POSIX path of (path to documents folder ...)'  → /var/mobile/Documents
//   osascript -l JavaScript -e <面板脚本> "Select Workspace Directory" → 固定工作目录
//   （脚本形式的 shim 不行：iOS 的 node 对脚本 exec 返回 EPERM，必须是 Mach-O）
// 目标目录可用环境变量 DSH_PICK_DIR 覆盖，默认 /var/mobile/Documents/dsh-workspace。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int contains(const char *hay, const char *needle) {
    return hay && needle && strstr(hay, needle) != NULL;
}

int main(int argc, char **argv) {
    int picker = 0, docs = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "JavaScript") == 0) picker = 1;
        else if (contains(argv[i], "path to documents folder")) docs = 1;
        else if (contains(argv[i], "choose folder")) picker = 1;
    }
    const char *dir = getenv("DSH_PICK_DIR");
    if (!dir || !*dir) dir = "/var/mobile/Documents/dsh-workspace";

    if (picker) {
        mkdir(dir, 0755);
        printf("%s\n", dir);
        return 0;
    }
    if (docs) {
        printf("/var/mobile/Documents\n");
        return 0;
    }
    return 0; // 其它调用：静默成功（等价于“取消”）
}
