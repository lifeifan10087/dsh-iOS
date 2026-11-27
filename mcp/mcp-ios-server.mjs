#!/usr/bin/env node
// mcp-ios-server.mjs —— iOS 侧的最小 MCP server（stdio，换行分隔 JSON-RPC）
//
// dsh 的 mcp-client 把它当 stdio server 挂上，工具名会变成 mcp__ios__<tool>。
// 设计原则：只用 iOS/越狱上真实存在的命令（uiopen / pbcopy / pbpaste / defaults），
// 缺哪个就只在那个工具里报清晰错误，不影响其它工具。
//
// 不依赖任何 npm 包（设备上装不了包）：协议部分手写。

import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);
const VERSION = "0.1.0";

// 越狱前缀：rootless 用 /var/jb，rootful 没有
const JB = existsSync("/var/jb") ? "/var/jb" : "";
const BIN = {
  uiopen: [`${JB}/usr/bin/uiopen`, "/usr/bin/uiopen"],
  pbcopy: [`${JB}/usr/bin/pbcopy`, "/usr/bin/pbcopy"],
  pbpaste: [`${JB}/usr/bin/pbpaste`, "/usr/bin/pbpaste"],
  sbbanner: [`${JB}/usr/bin/sbbanner`],
  sbalert: [`${JB}/usr/bin/sbalert`],
};

function which(name) {
  for (const p of BIN[name] || []) if (existsSync(p)) return p;
  return null;
}

async function sh(file, args = [], { input, timeoutMs = 15000 } = {}) {
  const opts = { timeout: timeoutMs, maxBuffer: 4 << 20 };
  if (input !== undefined) {
    return await new Promise((resolve, reject) => {
      const child = execFile(file, args, opts, (err, stdout, stderr) => {
        if (err) reject(Object.assign(err, { stderr }));
        else resolve({ stdout, stderr });
      });
      if (child.stdin) { child.stdin.end(input); }
    });
  }
  return await run(file, args, opts);
}

async function openURL(url) {
  const bin = which("uiopen");
  if (!bin) throw new Error("uiopen 不存在（安装 uikittools：sileo 搜 uikittools，或 apt-get install uikittools）");
  const { stdout, stderr } = await sh(bin, [url]);
  return `opened ${url}${stdout ? `\n${stdout.trim()}` : ""}${stderr ? `\n${stderr.trim()}` : ""}`;
}

function readSystemVersion() {
  try {
    const xml = readFileSync("/System/Library/CoreServices/SystemVersion.plist", "utf8");
    const grab = (k) => (xml.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`)) || [])[1] || "";
    return { name: grab("ProductName"), version: grab("ProductVersion"), build: grab("ProductBuildVersion") };
  } catch {
    return {};
  }
}

function listApps() {
  const roots = ["/Applications", `${JB}/Applications`].filter((p) => existsSync(p));
  const apps = [];
  for (const root of roots) {
    let entries = [];
    try { entries = readdirSync(root, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (!e.name.endsWith(".app")) continue;
      let bundleId = "";
      try {
        const plist = readFileSync(`${root}/${e.name}/Info.plist`);
        // 二进制的 Info.plist 里 CFBundleIdentifier 前后是 \0
        const text = plist.toString("latin1");
        const m = text.match(/CFBundleIdentifier[\s\S]{0,10}?([A-Za-z0-9._-]{3,80})/);
        if (m) bundleId = m[1].replace(/[^A-Za-z0-9._-]/g, "");
      } catch {}
      apps.push({ name: e.name.replace(/\.app$/, ""), bundleId, path: `${root}/${e.name}` });
    }
  }
  return apps;
}

const TOOLS = [
  {
    name: "clipboard_get",
    description: "读取 iOS 当前剪贴板文本",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const bin = which("pbpaste");
      if (!bin) throw new Error("pbpaste 不存在（装 uikittools）");
      const { stdout } = await sh(bin, []);
      return stdout || "(空)";
    },
  },
  {
    name: "clipboard_set",
    description: "把文本写入 iOS 剪贴板",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"], additionalProperties: false },
    run: async ({ text }) => {
      const bin = which("pbcopy");
      if (!bin) throw new Error("pbcopy 不存在（装 uikittools）");
      await sh(bin, [], { input: String(text ?? "") });
      return `已写入剪贴板（${String(text ?? "").length} 字符）`;
    },
  },
  {
    name: "open_url",
    description: "用系统打开 URL / 深链（tel:、sms:、https:、calshow: 等）",
    inputSchema: { type: "object", properties: { url: { type: "string" } }, required: ["url"], additionalProperties: false },
    run: async ({ url }) => openURL(String(url)),
  },
  {
    name: "open_app",
    description: "按 bundle id 打开 App",
    inputSchema: { type: "object", properties: { bundle_id: { type: "string" } }, required: ["bundle_id"], additionalProperties: false },
    run: async ({ bundle_id }) => {
      const bin = which("uiopen");
      if (!bin) throw new Error("uiopen 不存在（装 uikittools）");
      try { await sh(bin, ["--bundleid", String(bundle_id)]); return `opened ${bundle_id}`; }
      catch (e) {
        // 老版本 uiopen 不支持 --bundleid，退回用 app 路径
        const app = listApps().find((a) => a.bundleId === String(bundle_id));
        if (!app) throw new Error(`打不开 ${bundle_id}: ${(e.message || "").slice(0, 120)}`);
        await sh(bin, [app.path]);
        return `opened ${bundle_id} via ${app.path}`;
      }
    },
  },
  {
    name: "dial",
    description: "调起电话拨号（tel:）",
    inputSchema: { type: "object", properties: { number: { type: "string" } }, required: ["number"], additionalProperties: false },
    run: async ({ number }) => openURL(`tel:${String(number).replace(/[^0-9+*#]/g, "")}`),
  },
  {
    name: "sms_draft",
    description: "打开短信 App 并预填收件人与内容（不自动发送）",
    inputSchema: {
      type: "object",
      properties: { number: { type: "string" }, text: { type: "string" } },
      required: ["number"], additionalProperties: false,
    },
    run: async ({ number, text }) => {
      const to = String(number).replace(/[^0-9+*#]/g, "");
      const body = encodeURIComponent(String(text ?? ""));
      return openURL(`sms:${to}${body ? `&body=${body}` : ""}`);
    },
  },
  {
    name: "notify",
    description: "在设备上弹一条通知横幅（需要 sbutils 的 sbbanner）",
    inputSchema: {
      type: "object",
      properties: { title: { type: "string" }, body: { type: "string" } },
      required: ["title"], additionalProperties: false,
    },
    run: async ({ title, body }) => {
      const bin = which("sbbanner") || which("sbalert");
      if (!bin) throw new Error("没有 sbbanner/sbalert（apt-get install sbutils）");
      const msg = `${title}${body ? `\n${body}` : ""}`;
      const args = bin.endsWith("sbbanner") ? [msg] : ["-t", String(title), "-b", String(body ?? "")];
      await sh(bin, args);
      return "已弹出通知";
    },
  },
  {
    name: "device_info",
    description: "设备信息：机型、iOS 版本、越狱前缀、node 版本",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const sv = readSystemVersion();
      let machine = "";
      try { machine = (await sh("/usr/sbin/sysctl", ["-n", "hw.machine"])).stdout.trim(); } catch {}
      let model = "";
      try { model = (await sh("/usr/sbin/sysctl", ["-n", "hw.model"])).stdout.trim(); } catch {}
      return JSON.stringify({
        device: machine || model || "unknown",
        os: sv.name || "iOS",
        version: sv.version,
        build: sv.build,
        jailbreak: JB || "/ (rootful)",
        node: process.versions.node,
        platform: process.platform,
      }, null, 2);
    },
  },
  {
    name: "list_apps",
    description: "列出已安装 App（名称 + bundle id）",
    inputSchema: {
      type: "object",
      properties: { query: { type: "string", description: "可选：按名称/bundle id 过滤" } },
      additionalProperties: false,
    },
    run: async ({ query }) => {
      let apps = listApps();
      if (query) {
        const q = String(query).toLowerCase();
        apps = apps.filter((a) => a.name.toLowerCase().includes(q) || a.bundleId.toLowerCase().includes(q));
      }
      if (!apps.length) return "没有匹配的 App";
      return apps.map((a) => `${a.name}\t${a.bundleId || "?"}`).join("\n");
    },
  },
];

// —— 协议 ——
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}
const ok = (id, result) => send({ jsonrpc: "2.0", id, result });
const fail = (id, message, code = -32603) => send({ jsonrpc: "2.0", id, error: { code, message } });

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return ok(id, {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "dsh-ios", version: VERSION },
    });
  }
  if (method === "notifications/initialized" || method === "initialized") return;
  if (method === "ping") return ok(id, {});
  if (method === "tools/list") {
    return ok(id, {
      tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
    });
  }
  if (method === "resources/list") return ok(id, { resources: [] });
  if (method === "prompts/list") return ok(id, { prompts: [] });
  if (method === "tools/call") {
    const name = params?.name;
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) return fail(id, `unknown tool: ${name}`, -32602);
    try {
      const text = await tool.run(params?.arguments || {});
      return ok(id, { content: [{ type: "text", text: String(text) }], isError: false });
    } catch (e) {
      return ok(id, { content: [{ type: "text", text: `错误: ${e.message || e}` }], isError: true });
    }
  }
  if (id !== undefined) fail(id, `unsupported method: ${method}`, -32601);
}

let buf = "";
let pending = 0;
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    pending++;
    handle(msg)
      .catch((e) => { if (msg.id !== undefined) fail(msg.id, String(e?.message || e)); })
      .finally(() => { pending--; });
  }
});
process.stdin.on("end", () => {
  // 等手上还没回完的调用（客户端一次性喂几行再关 stdin 时别截断）
  const wait = () => (pending > 0 ? setTimeout(wait, 50) : process.exit(0));
  wait();
});
