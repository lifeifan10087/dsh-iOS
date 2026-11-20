#!/usr/bin/env node
// 从 Actions 拉最新产物并解包到 out/（不需要 gh / Mac）
// 用法: GITHUB_TOKEN=ghp_xxx node deploy/fetch-artifact.mjs <owner>/<repo> [name前缀]
import { writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [repo, prefix = "dsh-ios-kit"] = process.argv.slice(2);
const token = process.env.GITHUB_TOKEN;
if (!repo || !token) { console.error("用法: GITHUB_TOKEN=xxx node fetch-artifact.mjs owner/repo"); process.exit(1); }

const api = `https://api.github.com/repos/${repo}/actions/artifacts?per_page=50`;
const res = await fetch(api, { headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" } });
if (!res.ok) { console.error("列产物失败", res.status, await res.text()); process.exit(1); }
const list = (await res.json()).artifacts
  .filter((a) => a.name.startsWith(prefix) && !a.expired)
  .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
if (!list.length) { console.error("还没产物：编译可能仍在跑"); process.exit(1); }
const art = list[0];
console.log(`取 ${art.name} (${(art.size_in_bytes / 1e6).toFixed(1)}MB, ${art.created_at})`);

const zip = await fetch(art.archive_download_url, {
  headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" },
  redirect: "follow",
});
if (!zip.ok) { console.error("下载失败", zip.status); process.exit(1); }
const buf = Buffer.from(await zip.arrayBuffer());
mkdirSync("out", { recursive: true });
writeFileSync("/tmp/dsh-ios-kit.zip", buf);
execFileSync("python3", ["-m", "zipfile", "-e", "/tmp/dsh-ios-kit.zip", "out"], { stdio: "inherit" });
console.log("已解包到 out/：");
execFileSync("find", ["out", "-type", "f", "-exec", "ls", "-lh", "{}", ";"], { stdio: "inherit" });
console.log("\n下一步: DEVICE=root@<iPhone-IP> bash deploy/install-ios.sh out/node-ios-patched");
