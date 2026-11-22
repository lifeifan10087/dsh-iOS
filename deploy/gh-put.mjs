#!/usr/bin/env node
// 用 Contents API 上传文件（git 端口被墙时的替代）
// 用法: GITHUB_TOKEN=xxx node deploy/gh-put.mjs owner/repo file1 [file2 ...]
//
// 大陆网络到 api.github.com 会间歇性 ECONNABORTED / 握手超时，这里带重试与超时，
// 单文件失败不影响后续文件，最后用退出码汇总（有失败就是 1）。
import { readFileSync } from "node:fs";

const [repo, ...files] = process.argv.slice(2);
const t = process.env.GITHUB_TOKEN;
if (!repo || !files.length || !t) {
  console.error("用法: GITHUB_TOKEN=xxx node deploy/gh-put.mjs owner/repo file1 [file2 ...]");
  process.exit(2);
}
const h = {
  authorization: `Bearer ${t}`,
  accept: "application/vnd.github+json",
  "content-type": "application/json",
  "user-agent": "dsh-port",
  "x-github-api-version": "2022-11-28",
};

async function req(url, init, tries = 8) {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      return await fetch(url, { ...init, signal: AbortSignal.timeout(45000) });
    } catch (e) {
      last = e;
      const code = e?.cause?.code || e?.name || e?.message;
      console.error(`   retry ${i + 1}/${tries} ${code}`);
      await new Promise((r) => setTimeout(r, 1500 * (i + 1)));
    }
  }
  throw last;
}

let failed = 0;
for (const f of files) {
  const path = f.replace(/^\.\//, "");
  const content = readFileSync(f).toString("base64");
  let sha;
  try {
    const ex = await req(`https://api.github.com/repos/${repo}/contents/${path}`, { headers: h });
    if (ex.ok) sha = (await ex.json()).sha;
    else if (ex.status !== 404) console.error(`   GET ${ex.status} ${(await ex.text()).slice(0, 200)}`);
    const r = await req(`https://api.github.com/repos/${repo}/contents/${path}`, {
      method: "PUT",
      headers: h,
      body: JSON.stringify({ message: `update ${path}`, content, sha, branch: "main" }),
    });
    if (r.ok) {
      const j = await r.json();
      console.log(`OK ${r.status} ${path} -> ${j.commit?.sha?.slice(0, 8)}`);
    } else {
      failed++;
      console.log(`FAIL ${r.status} ${path}: ${(await r.text()).slice(0, 300)}`);
    }
  } catch (e) {
    failed++;
    console.log(`FAIL ${path}: ${e?.cause?.code || e?.message}`);
  }
}
process.exit(failed ? 1 : 0);
