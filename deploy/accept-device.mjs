#!/usr/bin/env node
// 设备侧自检探针：在 iPhone 上用 --jitless 跑，输出一行 JSON。
// 由 deploy/accept-device.sh 上传并执行，不要直接依赖它的排版。
import http from "node:http";

const out = { node: process.versions.node, nativePlatform: process.platform, nativeArch: process.arch };

// dsh 引擎是靠覆盖 process.platform 才认为自己在 darwin 上跑
try {
  Object.defineProperty(process, "platform", { value: "darwin" });
  Object.defineProperty(process, "arch", { value: "arm64" });
  out.shimPlatform = `${process.platform}/${process.arch}`;
} catch (e) {
  out.shimPlatform = "ERR:" + e.message;
}

try {
  out.unicode = new RegExp("[\\p{ID_Continue}]+", "u").test("a_1") ? "ok" : "mismatch";
} catch (e) {
  out.unicode = "ERR:" + e.message;
}

try {
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(":memory:");
  db.exec("create table t(a integer)");
  db.prepare("insert into t values (?)").run(1);
  out.sqlite = db.prepare("select count(*) c from t").get().c === 1 ? "ok" : "mismatch";
  db.close();
} catch (e) {
  out.sqlite = "ERR:" + e.message;
}

function get(url, { headers = {}, keepBody = false } = {}) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const req = http.get(
      { host: u.hostname, port: u.port || 80, path: u.pathname + u.search, timeout: 8000, headers },
      (res) => {
        let bytes = 0;
        const chunks = [];
        res.on("data", (c) => {
          bytes += c.length;
          if (keepBody && chunks.length < 64) chunks.push(c);
        });
        res.on("end", () =>
          resolve({ status: res.statusCode, bytes, body: Buffer.concat(chunks).toString("utf8") }),
        );
      },
    );
    req.on("timeout", () => { req.destroy(); resolve({ error: "TIMEOUT" }); });
    req.on("error", (e) => resolve({ error: e.code || e.message }));
    req.setTimeout(8000);
  });
}

// 1) 无 token 必须 401
out.root = await get("http://127.0.0.1:3080/");

// 2) 带 token 必须能拿到页面
const tokenUrl = process.env.DSH_URL || "";
if (tokenUrl) {
  const r = await get(tokenUrl, { keepBody: true });
  out.token = { status: r.status, bytes: r.bytes, hasHtml: /<html|<!doctype/i.test(r.body || ""), error: r.error };
} else {
  out.token = { error: "NO_URL" };
}

// 3) 引擎进程在不在（launchd 的名字）
try {
  const { execFileSync } = await import("node:child_process");
  out.procs = execFileSync("sh", ["-c", "ps -A -o pid,comm | grep -c '[n]ode' || true"], { encoding: "utf8" }).trim();
} catch (e) {
  out.procs = "ERR:" + e.message;
}

console.log(JSON.stringify(out));
process.exit(0);
