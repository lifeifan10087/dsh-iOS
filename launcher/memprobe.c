// memprobe —— 摸清 iOS 上「launchd 给守护进程的内存上限」到底是多少，以及能不能自己调高
//
// 用法：
//   memprobe                 只测量：每 32MB 分配并 touch，打印 RSS，直到被杀
//   memprobe 1500            先调 memorystatus_control 把本进程 jetsam 上限设成 1500MB 再测
//
// memorystatus_control 是私有 API（syscall 440），签名：
//   int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size)
// command 6 = MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT，buffer 是 int64_t（MB）
// 需要 entitlement: com.apple.private.memorystatus（见 build/entitlements.plist）

#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 7

static int msctl(uint32_t cmd, int32_t pid, uint32_t flags, void *buf, size_t sz) {
    return (int)syscall(440, cmd, pid, flags, buf, sz);
}

static void print_rss(const char *tag) {
    struct task_basic_info info;
    mach_msg_type_number_t cnt = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &cnt) == KERN_SUCCESS)
        printf("%s rss=%uMB\n", tag, (unsigned)(info.resident_size >> 20));
    fflush(stdout);
}

static int set_limit(int64_t mb) {
    errno = 0;
    int rc = msctl(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 0, &mb, sizeof(mb));
    printf("set_jetsam_task_limit(%lldMB) rc=%d errno=%d(%s)\n", (long long)mb, rc, errno, strerror(errno));
    fflush(stdout);
    return rc;
}

int main(int argc, char **argv) {
    printf("pid=%d\n", (int)getpid());

    // memprobe --exec <目标> [参数...]：设上限后 execv 过去。
    // 用来验证"exec 之后上限是否保留"，最终给 node 套一层。
    if (argc > 2 && strcmp(argv[1], "--exec") == 0) {
        const char *env = getenv("DSH_JETSAM_MB");
        int64_t mb = env ? atoll(env) : 1024;
        set_limit(mb);
        fflush(stdout);
        execv(argv[2], &argv[2]);
        perror("execv");
        return 1;
    }

    // 能不能读到自己的 memlimit 属性（结构是私有布局，只用来判断调用是否成功）
    uint64_t props[5] = {0};
    int rc = msctl(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, getpid(), 0, props, sizeof(props));
    printf("get_memlimit_properties rc=%d errno=%d(%s) props=%llu,%llu\n", rc, errno, strerror(errno),
           (unsigned long long)props[0], (unsigned long long)props[1]);

    if (argc > 1) {
        int64_t want = atoll(argv[1]);
        errno = 0;
        int r = msctl(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 0, &want, sizeof(want));
        printf("set_jetsam_task_limit(%lldMB) rc=%d errno=%d(%s)\n", (long long)want, r, errno, strerror(errno));
    }
    print_rss("before");

    const size_t step = 32ull << 20;
    size_t total = 0;
    for (int i = 0; i < 64; i++) {
        char *p = malloc(step);
        if (!p) { printf("malloc failed at %zuMB\n", total >> 20); break; }
        memset(p, (int)(i & 0xff), step);
        total += step;
        printf("allocated=%zuMB\n", total >> 20);
        fflush(stdout);
        usleep(150000);
    }
    print_rss("after");
    printf("survived=%zuMB\n", total >> 20);
    return 0;
}
