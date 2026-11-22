#!/usr/bin/env python3
"""校验 iOS node 产物：Linux/Android 上也能跑，不依赖 otool/vtool。

检查项：
  1. CPU 类型 = arm64
  2. LC_BUILD_VERSION.platform == 2 (iOS)，打印 minos / sdk
  3. 没有残留 LC_VERSION_MIN_MACOSX(0x24) / LC_VERSION_MIN_IPHONEOS 之外的 mac 平台标记
  4. 二进制里能搜到 "v22.20.0" 之类版本串（由 --version 常量内嵌）
  5. LC_CODE_SIGNATURE 是否存在（ldid 重签后应有）
用法: python3 deploy/verify-node-ios.py out/node-ios-patched [期望版本前缀, 默认 22.20]
退出码: 0 全过, 1 有关键项不过
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_CODE_SIGNATURE = 0x1D
PLATFORM_NAME = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "macCatalyst", 7: "iOS-simulator"}
CPU_ARM64 = 0x0100000C


def ver(v):
    return f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"


def scan(buf, off):
    magic = struct.unpack_from("<I", buf, off)[0]
    if magic != 0xFEEDFACF:
        return {"error": f"不是 64 位小端 Mach-O（magic=0x{magic:08x}）"}
    cputype, _sub, _ftype, ncmds, sizeofcmds = struct.unpack_from("<iiIII", buf, off + 4)
    out = {"cputype": cputype, "ncmds": ncmds, "sizeofcmds": sizeofcmds, "build_version": None,
           "macos_min": False, "iphoneos_min": None, "codesig": False}
    p = off + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, p)
        if cmd == LC_BUILD_VERSION:
            plat, minos, sdk, _ntools = struct.unpack_from("<IIII", buf, p + 8)
            out["build_version"] = (plat, ver(minos), ver(sdk))
        elif cmd == LC_VERSION_MIN_MACOSX:
            out["macos_min"] = True
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            out["iphoneos_min"] = ver(struct.unpack_from("<I", buf, p + 8)[0])
        elif cmd == LC_CODE_SIGNATURE:
            out["codesig"] = True
        p += cmdsize
        if cmdsize == 0:
            break
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else "22.20"
    buf = open(path, "rb").read()
    print(f"文件: {path}  ({len(buf) / 1e6:.1f} MB)")

    fat = struct.unpack_from(">I", buf, 0)[0] in (0xCAFEBABE, 0xCAFEBABF)
    infos = []
    if fat:
        nfat = struct.unpack_from(">I", buf, 4)[0]
        for i in range(nfat):
            base = 8 + i * 20
            off, size = struct.unpack_from(">II", buf, base + 8)
            print(f"  fat slice {i}: off={off} size={size}")
            infos.append((off, scan(buf, off)))
    else:
        infos.append((0, scan(buf, 0)))

    ok = True
    for off, info in infos:
        if "error" in info:
            print("  ✗", info["error"])
            ok = False
            continue
        arm = info["cputype"] == CPU_ARM64
        print(f"  {'✓' if arm else '✗'} cputype arm64 (0x{info['cputype'] & 0xFFFFFFFF:08x})")
        ok &= arm
        bv = info["build_version"]
        if bv:
            plat, minos, sdk = bv
            is_ios = plat == 2
            print(f"  {'✓' if is_ios else '✗'} LC_BUILD_VERSION platform={plat} "
                  f"({PLATFORM_NAME.get(plat, '?')}) minos={minos} sdk={sdk}")
            ok &= is_ios
        else:
            print("  ✗ 没有 LC_BUILD_VERSION")
            ok = False
        if info["macos_min"]:
            print("  ✗ 残留 LC_VERSION_MIN_MACOSX（安装时会拒装）")
            ok = False
        if info["iphoneos_min"]:
            print(f"  · 另有 LC_VERSION_MIN_IPHONEOS minos={info['iphoneos_min']}")
        print(f"  {'✓' if info['codesig'] else '·'} LC_CODE_SIGNATURE"
              f"{'' if info['codesig'] else '（未签名，设备上需 ldid -S）'}")

    hit = buf.find(want.encode())
    if hit >= 0:
        start = max(0, hit - 24)
        raw = buf[start:hit + len(want) + 24]
        printable = "".join(chr(c) if 32 <= c < 127 else "." for c in raw)
        print(f"  ✓ 找到版本串 {want!r} @0x{hit:x}: {printable}")
    else:
        print(f"  ✗ 未找到版本串 {want!r}")
        ok = False

    print("\n结果:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
