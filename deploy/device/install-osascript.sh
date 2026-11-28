#!/var/jb/bin/sh
# 装 Mach-O 的 osascript shim（iOS 没有 AppleScript；脚本形式会被 node 以 EPERM 拒绝）
# 用法：install-osascript.sh [源文件路径，默认与脚本同目录的 osascript-ios-arm64]
set -e
SRC="${1:-/var/mobile/Library/dsh/osascript-ios-arm64}"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
cp -f "$SRC" /var/jb/usr/bin/osascript
chmod 755 /var/jb/usr/bin/osascript
chown root:wheel /var/jb/usr/bin/osascript
ldid -S /var/jb/usr/bin/osascript 2>/dev/null || true
echo "已装 /var/jb/usr/bin/osascript"
echo "自检："
/var/jb/usr/bin/osascript -e 'POSIX path of (path to documents folder from user domain without folder creation)'
/var/jb/usr/bin/osascript -l JavaScript -e x "Select Workspace Directory"
