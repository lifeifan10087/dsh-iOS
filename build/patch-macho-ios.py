#!/usr/bin/env python3
"""把 macOS arm64 的 Mach-O（.node / 可执行 / dylib）的 LC_BUILD_VERSION 改成 iOS。
纯 Python 实现，不依赖 vtool/ldid —— 在 Linux/Android 上也能改。
用法: patch-macho-ios.py <file> [min_ios] [sdk]
说明: 只改平台号与 minos；签名需要另外用 ldid -S（设备上或 macOS 上做）。
"""
import struct, sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
PLATFORM_IOS = 2
PLATFORM_MACOS = 1


def patch_slice(buf: bytearray, off: int, minos: tuple, sdk: tuple) -> bool:
    magic = struct.unpack_from("<I", buf, off)[0]
    if magic in (0xFEEDFACF,):          # 64-bit little endian
        header = 32
        ncmds = struct.unpack_from("<I", buf, off + 16)[0]
    elif magic in (0xFEEDFACE,):
        header = 28
        ncmds = struct.unpack_from("<I", buf, off + 16)[0]
    else:
        return False
    p = off + header
    changed = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, p)
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", buf, p + 8)[0]
            if platform != PLATFORM_IOS:
                struct.pack_into("<I", buf, p + 8, PLATFORM_IOS)
                struct.pack_into("<I", buf, p + 12, minos[0] << 16 | minos[1])
                struct.pack_into("<I", buf, p + 16, sdk[0] << 16 | sdk[1])
                changed = True
        elif cmd == LC_VERSION_MIN_MACOSX:
            # 老式命令：直接把 cmd 换成 LC_BUILD_VERSION 需要改长度，这里只警告
            print("  ! 存在 LC_VERSION_MIN_MACOSX，需 vtool 处理")
        p += cmdsize
    return changed


def main():
    path = sys.argv[1]
    minos = tuple(int(x) for x in (sys.argv[2] if len(sys.argv) > 2 else "14.0").split("."))
    sdk = tuple(int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "18.0").split("."))
    buf = bytearray(open(path, "rb").read())
    magic = struct.unpack_from(">I", buf, 0)[0]
    changed = False
    if magic in (0xCAFEBABE, 0xCAFEBABF):     # fat
        nfat = struct.unpack_from(">I", buf, 4)[0]
        for i in range(nfat):
            base = 8 + i * 20
            off, size = struct.unpack_from(">II", buf, base + 8)
            if patch_slice(buf, off, minos, sdk):
                changed = True
    else:
        changed = patch_slice(buf, 0, minos, sdk)
    if changed:
        open(path, "wb").write(buf)
        print(f"  已改为 iOS {minos[0]}.{minos[1]} -> {path}")
    else:
        print(f"  无需修改（或没有 LC_BUILD_VERSION）: {path}")


if __name__ == "__main__":
    main()
