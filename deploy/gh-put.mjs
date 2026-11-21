#!/usr/bin/env node
// 用 Contents API 上传文件（git 端口被墙时的替代）
// 用法: GITHUB_TOKEN=xxx node deploy/gh-put.mjs owner/repo file1 [file2 ...]
import { readFileSync } from "node:fs";
const [repo, ...files] = process.argv.slice(2);
const t = process.env.GITHUB_TOKEN;
const h = { authorization: `Bearer ${t}`, accept: "application/vnd.github+json", "content-type": "application/json", "user-agent": "dsh-port" };
for (const f of files) {
  const path = f.replace(/^\.\//, "");
  const content = readFileSync(f).toString("base64");
  let sha;
  const ex = await fetch(`https://api.github.com/repos/${repo}/contents/${path}`, { headers: h });
  if (ex.ok) sha = (await ex.json()).sha;
  const r = await fetch(`https://api.github.com/repos/${repo}/contents/${path}`, { method: "PUT", headers: h, body: JSON.stringify({ message: `update ${path}`, content, sha, branch: "main" }) });
  console.log(`${r.status} ${path}`);
}
