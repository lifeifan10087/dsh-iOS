#!/usr/bin/env node
// 从 Actions 拉最新产物并解包到 out/（不需要 gh / Mac）
// 用法: GITHUB_TOKEN=xxx node deploy/fetch-artifact.mjs <owner>/<repo> [name前缀] [run_id]
//
// 设计要点（大陆线路不稳 + 手机热点慢）：
//   - 元数据走 api.github.com（间歇超时 → 重试）
//   - 包体走签名直链 objects.githubusercontent.com，**断点续传**：先解析 302 的
//     location，再用 Range: bytes=<已下载>- 续，失败不从头再来
//   - 边下边写 /tmp/dsh-ios-kit.zip.part，完成后才改名，避免半包被当成品
//   - 同名 zip 大小与远端一致时跳过下载，可重复执行
import { createWriteStream, existsSync, statSync, renameSync, mkdirSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const [repo, prefix = "dsh-ios-kit", runId] = process.argv.slice(2);
const token = process.env.GITHUB_TOKEN;
if (!repo || !token) {
  console.error("用法: GITHUB_TOKEN=xxx node deploy/fetch-artifact.mjs owner/repo [name前缀] [run_id]");
  process.exit(1);
}
const H = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "user-agent": "dsh-port" };
const UA = { "user-agent": "dsh-port" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mb = (n) => (n / 1e6).toFixed(1);

async function apiGet(url, tries = 10) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, { headers: H, signal: AbortSignal.timeout(45000) });
      if (r.ok) return r;
      if (r.status >= 400 && r.status < 500 && r.status !== 429) {
        console.error("HTTP", r.status, (await r.text()).slice(0, 200));
        return null;
      }
      console.error("HTTP", r.status, "retry");
    } catch (e) {
      console.error("meta retry", i + 1, e?.cause?.code || e?.message);
    }
    await sleep(2000 * (i + 1));
  }
  return null;
}

const listUrl = runId
  ? `https://api.github.com/repos/${repo}/actions/runs/${runId}/artifacts`
  : `https://api.github.com/repos/${repo}/actions/artifacts?per_page=50`;
const res = await apiGet(listUrl);
if (!res) { console.error("列产物失败"); process.exit(1); }
const list = (await res.json()).artifacts
  .filter((a) => a.name.startsWith(prefix) && !a.expired)
  .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
if (!list.length) { console.error("还没产物：编译可能仍在跑"); process.exit(1); }
const art = list[0];
const total = art.size_in_bytes;
const zipPath = "/tmp/dsh-ios-kit.zip";
const partPath = zipPath + ".part";
console.log(`取 ${art.name} (${mb(total)}MB, ${art.created_at})`);

function localSize(p) { try { return statSync(p).size; } catch { return -1; } }

if (localSize(zipPath) === total) {
  console.log("  本地 zip 大小一致，跳过下载");
  rmSync(partPath, { force: true });
} else {
  // 1) 解析签名直链（不跟随，拿 location）
  let direct = null;
  for (let i = 0; i < 10 && !direct; i++) {
    try {
      const r = await fetch(art.archive_download_url, { headers: H, redirect: "manual", signal: AbortSignal.timeout(45000) });
      if (r.status >= 300 && r.status < 400) direct = r.headers.get("location");
      else if (r.ok) direct = art.archive_download_url; // 没重定向就直接用
      else console.error("直链解析 HTTP", r.status);
      if (r.body) await r.body.cancel().catch(() => {});
    } catch (e) {
      console.error("直链重试", i + 1, e?.cause?.code || e?.message);
    }
    if (!direct) await sleep(1500 * (i + 1));
  }
  if (!direct) { console.error("拿不到签名直链"); process.exit(1); }

  // 1.5) 选线路：签名直链在 Azure blob，大陆单连接只有 ~40KB/s；
  //      gh-proxy.com 这类镜像能给到 MB/s。用 1MB Range 探速，挑最快的。
  const candidates = [`${direct}`, ...(process.env.MIRRORS ?? "https://gh-proxy.com/")
    .split(",").map((s) => s.trim()).filter(Boolean)
    .map((p) => (p.endsWith("/") ? p : p + "/") + direct)];
  const probes = await Promise.all(candidates.map(async (u, i) => {
    const t0 = Date.now();
    try {
      const r = await fetch(u, { headers: { ...UA, Range: "bytes=0-1048575" }, signal: AbortSignal.timeout(20000) });
      let n = 0;
      for await (const c of r.body) n += c.length;
      return { u, i, kbps: Math.round(n / 1024 / ((Date.now() - t0) / 1000)) };
    } catch {
      return { u, i, kbps: -1 };
    }
  }));
  probes.sort((a, b) => b.kbps - a.kbps);
  for (const p of probes) console.log(`  线路 ${p.i === 0 ? "直连" : "镜像" + p.i}: ${p.kbps} KB/s`);
  if (probes[0].kbps <= 0) { console.error("所有线路都不通"); process.exit(1); }
  direct = probes[0].u;
  console.log(`  选用: ${probes[0].i === 0 ? "直连" : "镜像" + probes[0].i}（${probes[0].kbps} KB/s）`);

  // 2) 断点续传
  let done = false;
  for (let attempt = 1; attempt <= 40 && !done; attempt++) {
    const have = Math.max(0, localSize(partPath));
    if (have >= total) { done = true; break; }
    if (have > 0) console.log(`  续传 attempt=${attempt} 已有 ${mb(have)}MB / ${mb(total)}MB`);
    else console.log(`  下载 attempt=${attempt}`);
    try {
      const r = await fetch(direct, {
        headers: { ...UA, ...(have > 0 ? { Range: `bytes=${have}-` } : {}) },
        redirect: "follow",
        signal: AbortSignal.timeout(30 * 60 * 1000),
      });
      if (!(r.status === 200 || r.status === 206)) throw new Error("HTTP " + r.status);
      if (r.status === 200 && have > 0) {
        console.log("  服务端不支持 Range，从头下");
        rmSync(partPath, { force: true });
      }
      const out = createWriteStream(partPath, { flags: "a" });
      await pipeline(Readable.fromWeb(r.body), out);
      const now = localSize(partPath);
      console.log(`  本段完成，累计 ${mb(now)}MB / ${mb(total)}MB`);
      if (now >= total) done = true;
    } catch (e) {
      console.error("  中断:", e?.cause?.code || e?.message);
      await sleep(2500 * Math.min(attempt, 6));
    }
  }
  if (!done) { console.error("下载没完成，.part 保留可续传"); process.exit(1); }
  const got = localSize(partPath);
  if (got !== total) { console.error(`大小不符 ${got} != ${total}`); process.exit(1); }
  rmSync(zipPath, { force: true });
  renameSync(partPath, zipPath);
  console.log(`  已下载 ${mb(got)}MB`);
}

mkdirSync("out", { recursive: true });
execFileSync("python3", ["-m", "zipfile", "-e", zipPath, "out"], { stdio: "inherit" });
console.log("已解包到 out/：");
execFileSync("find", ["out", "-maxdepth", "2", "-type", "f", "-exec", "ls", "-lh", "{}", ";"], { stdio: "inherit" });
console.log("\n下一步: python3 deploy/verify-node-ios.py out/node-ios-patched 22.20");
