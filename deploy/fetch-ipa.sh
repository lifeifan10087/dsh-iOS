#!/usr/bin/env bash
# 从 CI 取回 DshGo.ipa 并放到手机存储的下载目录
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.secrets.env; set +a
RUN="${1:-}"
node - "$RUN" <<'JS'
const T = process.env.GITHUB_TOKEN;
const fs = require("fs");
const run = process.argv[2];
const h = { authorization: `Bearer ${T}`, accept: "application/vnd.github+json", "user-agent": "dsh-port" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function get(url, tries = 8) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url, { headers: h, signal: AbortSignal.timeout(45000) }); if (r.ok) return r; } catch {}
    await sleep(2000);
  }
  throw new Error("give up " + url);
}
(async () => {
  const listUrl = run
    ? `https://api.github.com/repos/lifeifan10087/dsh-iOS/actions/runs/${run}/artifacts`
    : `https://api.github.com/repos/lifeifan10087/dsh-iOS/actions/artifacts?per_page=20`;
  const list = (await (await get(listUrl)).json()).artifacts
    .filter((a) => a.name.startsWith("dshgo-ipa") && !a.expired)
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  if (!list.length) { console.error("还没有 IPA 产物"); process.exit(1); }
  const art = list[0];
  console.log(`取 ${art.name} (${(art.size_in_bytes / 1e6).toFixed(2)}MB, ${art.created_at})`);
  const zip = await get(art.archive_download_url);
  const buf = Buffer.from(await zip.arrayBuffer());
  fs.writeFileSync("/tmp/dshgo-ipa.zip", buf);
  console.log("已下载", (buf.length / 1e6).toFixed(2), "MB");
})();
JS
rm -rf /tmp/dshgo-ipa && mkdir -p /tmp/dshgo-ipa
python3 -m zipfile -e /tmp/dshgo-ipa.zip /tmp/dshgo-ipa
IPA=$(find /tmp/dshgo-ipa -name "*.ipa" | head -1)
[ -n "$IPA" ] || { echo "压缩包里没有 ipa"; ls -R /tmp/dshgo-ipa | head; exit 1; }
mkdir -p /sdcard/Download/DSH-Go
cp -f "$IPA" /sdcard/Download/DSH-Go/DshGo.ipa
ls -lh /sdcard/Download/DSH-Go/DshGo.ipa
