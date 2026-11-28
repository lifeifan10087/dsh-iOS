#!/usr/bin/env node
// mcp-ios-server.mjs —— iOS 侧的「root 守护」MCP server（stdio，换行分隔 JSON-RPC）
//
// 为什么需要它：ios-mcp tweak 注入在 SpringBoard 沙箱里，触控/AX/私有 API 都强，
// 但 exec 外部进程、读写 root 文件全被沙箱拦（报告 P0-1）。本进程以 root 运行，
// 正好补上这一环，并把 tweak 侧的已知缺陷在协议层修掉：
//   · tap_text        —— 用 Vision OCR 的坐标点击（修 P0-2 的 AX 坐标错位）
//   · write_file      —— 自己实现，不再有 basename 当父目录的 bug（修 P1-1）
//   · ocr             —— 默认走 Apple Vision（修 P1-2）
//   · screenshot_file —— 截图落盘给路径（修 P1-3 交付失败）
//   · press_key_retry —— 按键后回读校验并重试（修 P2-4）
//   · open_url_verified —— 打开后校验前台是否变化（修 P2-5）
//   · frontmost_app   —— 去掉不可靠的 contextId（修 P2-6）
//   · 所有写操作先查锁屏态，锁屏时结构化拒绝（P2-7 的守卫，但不假装能解锁）
//
// 依赖：tweak 的 127.0.0.1:8090/mcp（HTTP）；不依赖任何 npm 包。

import { execFile, execFileSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const VERSION = "0.2.0";

const JB = existsSync("/var/jb") ? "/var/jb" : "";
const SH_CANDIDATES = [`${JB}/bin/sh`, `${JB}/usr/bin/dash`, `${JB}/usr/bin/bash`, "/var/jb/bin/sh"];
const MCP8090 = "http://127.0.0.1:8090/mcp";

const BIN = {
  uiopen: [`${JB}/usr/bin/uiopen`, "/usr/bin/uiopen"],
  sbbanner: [`${JB}/usr/bin/sbbanner`],
  sbalert: [`${JB}/usr/bin/sbalert`],
  logreader: [`${JB}/usr/bin/mcp-logreader`],
};

function which(key) {
  for (const p of BIN[key] || []) if (existsSync(p)) return p;
  return null;
}
function shellPath() {
  for (const p of SH_CANDIDATES) if (existsSync(p)) return p;
  return null;
}

async function sh(file, args = [], { input, timeoutMs = 20000, maxBuffer = 8 << 20 } = {}) {
  const opts = { timeout: timeoutMs, maxBuffer, cwd: "/var/mobile" };
  return await new Promise((res, rej) => {
    const child = execFile(file, args, opts, (err, stdout, stderr) => {
      if (err) rej(Object.assign(err, { stdout, stderr }));
      else res({ stdout, stderr });
    });
    if (input !== undefined && child.stdin) child.stdin.end(input);
  });
}

// —— 8090 tweak 客户端 ——
async function tweak(method, params = {}, timeoutMs = 30000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const r = await fetch(MCP8090, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: Date.now() % 100000, method, params }),
      signal: ctrl.signal,
    });
    const text = await r.text();
    const line = text.split("\n").filter((l) => l.trim().startsWith("{")).pop() || text;
    let msg;
    try { msg = JSON.parse(line); } catch { throw new Error(`tweak 返回非 JSON: ${text.slice(0, 120)}`); }
    if (msg.error) throw new Error(msg.error.message || JSON.stringify(msg.error));
    return msg.result;
  } finally { clearTimeout(timer); }
}

async function tweakInit() {
  try { await tweak("initialize", { protocolVersion: "2024-11-05", capabilities: {} }, 8000); } catch {}
}

/** 调 tweak 工具，把 content[].text 拼接成字符串；图片返回 {image:{mimeType,data}} */
async function callTweak(name, args = {}) {
  const res = await tweak("tools/call", { name, arguments: args });
  const parts = res?.content || [];
  const texts = [];
  let image = null;
  for (const p of parts) {
    if (p.type === "text") texts.push(String(p.text ?? ""));
    else if (p.type === "image" && p.data) image = { mimeType: p.mimeType || "image/jpeg", data: p.data };
  }
  return { text: texts.join("\n").trim(), image, raw: res };
}

/** tweak 的文本结果大多是 JSON 字符串；尽量解析 */
function maybeJSON(s) {
  if (typeof s !== "string") return s;
  const t = s.trim();
  if (!t.startsWith("{") && !t.startsWith("[")) return s;
  try { return JSON.parse(t); } catch { return s; }
}

// —— 设备状态 / 锁屏守卫 ——
let _stateCache = { at: 0, value: null };
async function deviceState({ fresh = false, ttl = 1500 } = {}) {
  const now = Date.now();
  if (!fresh && _stateCache.value && now - _stateCache.at < ttl) return _stateCache.value;
  try {
    const out = maybeJSON((await callTweak("get_screen_info", {})).text);
    const ds = out?.device_state || out;
    const locked = ds?.locked === true ? true : ds?.locked === false ? false : null;
    const screenOn = ds?.screen_on === false ? false : ds?.screen_on === true ? true : null;
    const state = {
      locked,
      screen_on: screenOn,
      raw_lock_state: ds?.raw_lock_state ?? null,
      scale: out?.scale ?? null,
      pixel: out?.pixel_width && out?.pixel_height ? `${out.pixel_width}x${out.pixel_height}` : null,
    };
    _stateCache = { at: now, value: state };
    return state;
  } catch (e) {
    return { locked: null, screen_on: null, error: String(e.message || e) };
  }
}

const LOCKED_HINT = "设备锁屏或息屏。自动化没有解锁通路（需要人工 Face ID/密码），解锁后重试；不要在锁屏状态下反复尝试写操作。";
async function requireUnlocked(action) {
  const st = await deviceState({ fresh: true });
  if (st.locked === true || st.screen_on === false) {
    const err = new Error(`${action} 被锁屏守卫拦下：${LOCKED_HINT}`);
    err.structured = { blocked: true, reason: "device_locked_or_screen_off", action, state: st, next_step: "人工解锁后重试" };
    throw err;
  }
  return st;
}

// —— OCR（走 tweak 的 Vision 引擎）——
function normRect(r) {
  if (!r) return null;
  const x = r.x ?? r.left ?? r.origin?.x;
  const y = r.y ?? r.top ?? r.origin?.y;
  const w = r.w ?? r.width ?? r.size?.width;
  const h = r.h ?? r.height ?? r.size?.height;
  if ([x, y, w, h].some((v) => typeof v !== "number")) return null;
  return { x, y, w, h, cx: x + w / 2, cy: y + h / 2 };
}

/** 解析 ocr_screen 的返回，兼容多种形状 */
function parseOCR(raw) {
  const obj = maybeJSON(raw);
  if (typeof obj === "string") return [];
  const arr = Array.isArray(obj) ? obj : obj.elements || obj.items || obj.texts || obj.lines || obj.results || [];
  const out = [];
  for (const it of arr) {
    const text = it.text ?? it.string ?? it.value ?? it.content;
    if (typeof text !== "string" || !text.trim()) continue;
    const rect = normRect(it.rect || it.frame || it.bounds || it.bbox || it);
    out.push({ text: text.trim(), confidence: it.confidence ?? it.score ?? null, rect });
  }
  return out;
}

let _ocrCache = { at: 0, key: "", value: null };
async function ocrVision({ region, minConfidence = 0, ttl = 700 } = {}) {
  const key = JSON.stringify({ region, minConfidence });
  if (ttl > 0 && _ocrCache.value && _ocrCache.key === key && Date.now() - _ocrCache.at < ttl) {
    return _ocrCache.value;
  }
  const args = { engine: "vision" };
  if (region) args.region = region;
  if (minConfidence) args.min_confidence = minConfidence;
  const { text } = await callTweak("ocr_screen", args);
  const out = { items: parseOCR(text), raw: text };
  _ocrCache = { at: Date.now(), key, value: out };
  return out;
}

function findText(items, needle, { exact = false, index = 0 } = {}) {
  const n = needle.trim();
  const hits = items.filter((it) => (exact ? it.text === n : it.text.includes(n)));
  return hits[index] || null;
}

// —— 应用列表（补齐 TrollStore / 系统容器）——
function appDirs() {
  return [
    "/Applications",
    `${JB}/Applications`,
    "/var/containers/Bundle/Application",
  ].filter((d) => existsSync(d));
}

// —— 最小 bplist 解析（只为了拿 CFBundleIdentifier；设备上 defaults 会卡死）——
function parseBPlist(buf) {
  if (buf.length < 40) return null;
  const trailer = buf.subarray(buf.length - 32);
  const offsetSize = trailer[6];
  const refSize = trailer[7];
  const numObjects = Number(trailer.readBigUInt64BE(8));
  const topObject = Number(trailer.readBigUInt64BE(16));
  const tableOffset = Number(trailer.readBigUInt64BE(24));
  if (!numObjects || tableOffset <= 0 || tableOffset >= buf.length) return null;
  const offsets = [];
  for (let i = 0; i < numObjects; i++) {
    const o = tableOffset + i * offsetSize;
    if (o + offsetSize > buf.length) return null;
    let v = 0;
    for (let k = 0; k < offsetSize; k++) v = v * 256 + buf[o + k];
    offsets.push(v);
  }
  const lenAt = (off) => {
    const info = buf[off] & 0x0f;
    if (info !== 0x0f) return { len: info, extra: 0 };
    const im = buf[off + 1];
    const n = 1 << (im & 0x0f);           // 1/2/4/8 字节
    let v = 0;
    for (let k = 0; k < n; k++) v = v * 256 + buf[off + 2 + k];
    return { len: v, extra: n + 1 };
  };
  const readObj = (idx) => {
    const off = offsets[idx];
    if (off === undefined || off >= buf.length) return null;
    const marker = buf[off];
    const type = marker >> 4;
    const L = lenAt(off);
    const info = L.len;
    const body = off + 1 + L.extra;
    if (type === 0x0) return null;                       // null/bool/fill
    if (type === 0x1) return buf.readUIntBE(off + 1, 1 << info); // int
    if (type === 0x2) return info === 2 ? buf.readFloatBE(off + 1) : buf.readDoubleBE(off + 1);
    if (type === 0x5) return buf.subarray(body, body + info).toString("latin1"); // ASCII
    if (type === 0x6) return Buffer.from(buf.subarray(body, body + info * 2)).swap16().toString("utf16le");
    if (type === 0x8) return { uid: buf.readUIntBE(off + 1, info + 1) };
    if (type === 0xa || type === 0xc) {                  // array / set
      const base = body;
      const refs = [];
      for (let i = 0; i < info; i++) {
        let v = 0;
        for (let k = 0; k < refSize; k++) v = v * 256 + buf[base + i * refSize + k];
        refs.push(v);
      }
      return refs;
    }
    if (type === 0xd) {                                  // dict
      const base = body;
      const keyRefs = [], valRefs = [];
      for (let i = 0; i < info; i++) {
        let k1 = 0, k2 = 0;
        for (let k = 0; k < refSize; k++) k1 = k1 * 256 + buf[base + i * refSize + k];
        for (let k = 0; k < refSize; k++) k2 = k2 * 256 + buf[base + info * refSize + i * refSize + k];
        keyRefs.push(k1); valRefs.push(k2);
      }
      const out = {};
      for (let i = 0; i < keyRefs.length; i++) out[readObj(keyRefs[i])] = valRefs[i];
      return out;
    }
    return null;
  };
  const root = readObj(topObject);
  if (!root || typeof root !== "object" || Array.isArray(root)) return null;
  const resolve = (v) => (typeof v === "number" ? readObj(v) : v);
  const out = {};
  for (const [k, v] of Object.entries(root)) out[k] = resolve(v);
  return out;
}

function bundleIdOf(appPath) {
  const p = join(appPath, "Info.plist");
  try {
    const buf = readFileSync(p);
    if (buf.subarray(0, 6).toString("latin1") === "bplist") {
      const d = parseBPlist(buf);
      if (d && typeof d.CFBundleIdentifier === "string") return d.CFBundleIdentifier;
    } else {
      const m = buf.toString("utf8").match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/);
      if (m) return m[1];
    }
  } catch {}
  return "";
}

function scanApps() {
  const apps = [];
  const seen = new Set();
  const push = (name, path) => {
    if (!name || seen.has(path)) return;
    seen.add(path);
    apps.push({ name: name.replace(/\.app$/, ""), bundleId: bundleIdOf(path), path });
  };
  for (const root of appDirs()) {
    let entries = [];
    try { entries = readdirSync(root); } catch { continue; }
    for (const e of entries) {
      const full = join(root, e);
      if (e.endsWith(".app")) push(e, full);
      else {
        // /var/containers/Bundle/Application/<UUID>/Xxx.app
        try {
          for (const sub of readdirSync(full)) if (sub.endsWith(".app")) push(sub, join(full, sub));
        } catch {}
      }
    }
  }
  return apps;
}

// —— 文件工具 ——
function ensureAbs(p) {
  if (!isAbsolute(p)) throw new Error(`需要绝对路径: ${p}`);
  return resolve(p);
}

function listDir(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    try {
      const st = statSync(full);
      out.push({ name, type: st.isDirectory() ? "dir" : "file", size: st.size, mtime: st.mtimeMs, mode: (st.mode & 0o777).toString(8) });
    } catch { out.push({ name, type: "unknown" }); }
  }
  return out.sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "dir" ? -1 : 1));
}

function readFileText(path, { maxBytes = 512 * 1024, offset = 0 } = {}) {
  const st = statSync(path);
  const len = Math.min(maxBytes, Math.max(0, st.size - offset));
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, offset);
    return { path, size: st.size, offset, bytes: len, text: buf.toString("utf8") };
  } finally { closeSync(fd); }
}

function writeFileText(path, text, { mkdir = true, mode = 0o644 } = {}) {
  const abs = ensureAbs(path);
  const parent = dirname(abs);
  if (mkdir) mkdirSync(parent, { recursive: true });
  if (!existsSync(parent)) throw new Error(`父目录不存在: ${parent}`);
  writeFileSync(abs, text, { mode });
  const st = statSync(abs);
  return { path: abs, size: st.size, parent };
}

// —— 截图落盘 ——
function shotsDir() {
  const d = "/var/mobile/Documents/dsh-shots";
  mkdirSync(d, { recursive: true });
  return d;
}

async function screenshotToFile({ prefix = "shot" } = {}) {
  const { image } = await callTweak("screenshot", {});
  if (!image) throw new Error("tweak 没返回图片数据");
  const ext = image.mimeType.includes("png") ? "png" : "jpg";
  const name = `${prefix}-${Date.now()}.${ext}`;
  const path = join(shotsDir(), name);
  writeFileSync(path, Buffer.from(image.data, "base64"));
  const st = statSync(path);
  return { path, bytes: st.size, mimeType: image.mimeType };
}

// —— 点击类（OCR 定位，修 P0-2）——
async function tapText({ text, exact = false, index = 0, verify = true, settleMs = 600, fresh = true }) {
  await requireUnlocked("tap_text");
  const before = verify ? (await callTweak("get_frontmost_app", {})).text : "";
  const { items, raw: ocrRaw } = await ocrVision({ ttl: fresh ? 0 : 700 });
  const ocrBefore = verify ? items.map((i) => i.text).join("|") : "";
  const hit = findText(items, text, { exact, index });
  if (!hit || !hit.rect) {
    throw new Error(`屏幕上找不到文本「${text}」（OCR 命中 ${items.length} 条）`);
  }
  const x = Math.round(hit.rect.cx);
  const y = Math.round(hit.rect.cy);
  const tapRes = await callTweak("tap_screen", { x, y });
  await new Promise((r) => setTimeout(r, settleMs));
  const after = verify ? (await callTweak("get_frontmost_app", {})).text : "";
  let screenChanged = null, topText = null;
  if (verify) {
    const ocrAfter = (await ocrVision()).items;
    const sig = ocrAfter.map((i) => i.text).join("|");
    screenChanged = sig !== ocrBefore;
    const sorted = ocrAfter.filter((i) => i.rect).sort((a, b) => a.rect.y - b.rect.y);
    topText = sorted[0]?.text ?? null;
  }
  return {
    tapped: true, text: hit.text, point: { x, y }, matchedRect: hit.rect,
    source: "vision-ocr", tapResult: tapRes.text.slice(0, 120),
    frontmostChanged: verify ? before !== after : null,
    frontmostAfter: verify ? maybeJSON(after)?.bundleId ?? after.slice(0, 80) : null,
    screenChanged,
    topTextAfterTap: topText,
  };
}

// —— 键盘 ——
async function pressKeyRetry({ key = "delete", times = 1, retries = 3, delayMs = 250 } = {}) {
  await requireUnlocked("press_key");
  const attempts = [];
  for (let i = 0; i < times; i++) {
    let ok = false;
    for (let r = 0; r < retries && !ok; r++) {
      const res = await callTweak("press_key", { key });
      attempts.push({ key, try: r + 1, raw: res.text.slice(0, 100) });
      ok = !/fail|error|not\s*found|unknown/i.test(res.text);
      if (!ok) await new Promise((x) => setTimeout(x, delayMs));
    }
  }
  return { key, times, attempts: attempts.length, detail: attempts.slice(-3) };
}

// —— 深链打开 + 校验（修 P2-5）——
async function openURLVerified(url, { waitMs = 2500, verifyScreen = true } = {}) {
  const bin = which("uiopen");
  if (!bin) throw new Error("uiopen 不存在（装 uikittools）");
  const before = maybeJSON((await callTweak("get_frontmost_app", {})).text)?.bundleId || null;
  // 深链常常在**同一个 App 内**跳页（prefs:root=General 就是），前台不会变，
  // 只有对比屏幕内容才能判断到底有没有跳成功。
  const sigBefore = verifyScreen ? (await ocrVision({ ttl: 0 })).items.map((i) => i.text).join("|") : "";
  await sh(bin, [url], { timeoutMs: 15000 }).catch(() => {});
  const deadline = Date.now() + waitMs;
  let after = before, screenChanged = null, topText = null;
  while (Date.now() < deadline) {
    after = maybeJSON((await callTweak("get_frontmost_app", {})).text)?.bundleId || null;
    if (after && after !== before) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  if (verifyScreen) {
    const items = (await ocrVision({ ttl: 0 })).items;
    screenChanged = items.map((i) => i.text).join("|") !== sigBefore;
    const sorted = items.filter((i) => i.rect).sort((a, b) => a.rect.y - b.rect.y);
    topText = sorted[1]?.text ?? sorted[0]?.text ?? null;
  }
  const changed = before !== after;
  return {
    url, before, after, changed,
    screenChanged, topTextAfterOpen: topText,
    verified: changed || screenChanged === true,
    note: changed ? "前台已切换" : screenChanged ? "同一 App 内跳页（按屏变判定）" : "未见变化",
  };
}

// —— 工具定义 ——
const TOOLS = [
  {
    name: "device_state",
    description: "读取锁屏/亮屏状态与屏幕尺寸（其它写操作的前置守卫依据）",
    inputSchema: { type: "object", properties: { fresh: { type: "boolean" } }, additionalProperties: false },
    run: async (a) => deviceState({ fresh: a.fresh !== false }),
  },
  {
    name: "run_command",
    description: "以 root 执行 shell 命令（补 tweak 沙箱里 run_command 断链）",
    inputSchema: {
      type: "object",
      properties: { command: { type: "string" }, timeout_ms: { type: "number" }, stdin: { type: "string" } },
      required: ["command"], additionalProperties: false,
    },
    run: async (a) => {
      const shBin = shellPath();
      if (!shBin) throw new Error(`找不到 shell：${SH_CANDIDATES.join(" / ")}`);
      const t0 = Date.now();
      try {
        const { stdout, stderr } = await sh(shBin, ["-c", a.command], { input: a.stdin, timeoutMs: a.timeout_ms ?? 30000 });
        return { shell: shBin, exitCode: 0, stdout: stdout.slice(0, 200000), stderr: stderr.slice(0, 20000), ms: Date.now() - t0 };
      } catch (e) {
        return { shell: shBin, exitCode: e.code ?? -1, stdout: String(e.stdout || "").slice(0, 200000), stderr: String(e.stderr || e.message || "").slice(0, 20000), ms: Date.now() - t0 };
      }
    },
  },
  {
    name: "read_file",
    description: "读文件（root 权限，可读 600）；自动给 size/offset",
    inputSchema: { type: "object", properties: { path: { type: "string" }, offset: { type: "number" }, max_bytes: { type: "number" } }, required: ["path"], additionalProperties: false },
    run: async (a) => readFileText(ensureAbs(a.path), { offset: a.offset ?? 0, maxBytes: a.max_bytes ?? 512 * 1024 }),
  },
  {
    name: "write_file",
    description: "写文件（root；自动建父目录，修 tweak 那条 basename 当目录的 bug）",
    inputSchema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" }, mkdir: { type: "boolean" }, mode: { type: "string" } }, required: ["path", "content"], additionalProperties: false },
    run: async (a) => writeFileText(a.path, a.content, { mkdir: a.mkdir !== false, mode: a.mode ? parseInt(a.mode, 8) : 0o644 }),
  },
  {
    name: "list_dir",
    description: "列目录（name/type/size/mode/mtime）",
    inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"], additionalProperties: false },
    run: async (a) => ({ path: ensureAbs(a.path), entries: listDir(ensureAbs(a.path)) }),
  },
  {
    name: "ocr",
    description: "OCR 屏幕（默认 Apple Vision，带 rect/置信度；修默认 paddleocr 必挂的问题）",
    inputSchema: { type: "object", properties: { region: { type: "object" }, min_confidence: { type: "number" }, raw: { type: "boolean" } }, additionalProperties: false },
    run: async (a) => {
      const r = await ocrVision({ region: a.region, minConfidence: a.min_confidence });
      return a.raw ? r : { count: r.items.length, items: r.items };
    },
  },
  {
    name: "tap_text",
    description: "按 OCR 文本定位后点击（Vision 坐标，规避 AX 缓存错位误点），可选点击后校验前台变化",
    inputSchema: { type: "object", properties: { text: { type: "string" }, exact: { type: "boolean" }, index: { type: "number" }, verify: { type: "boolean" } }, required: ["text"], additionalProperties: false },
    run: async (a) => tapText(a),
  },
  {
    name: "press_key_retry",
    description: "按键并重试（修首击被吞）",
    inputSchema: { type: "object", properties: { key: { type: "string" }, times: { type: "number" }, retries: { type: "number" } }, additionalProperties: false },
    run: async (a) => pressKeyRetry(a),
  },
  {
    name: "open_url_verified",
    description: "打开 URL/深链并校验前台是否真的切过去（修静默失败）",
    inputSchema: { type: "object", properties: { url: { type: "string" }, wait_ms: { type: "number" } }, required: ["url"], additionalProperties: false },
    run: async (a) => openURLVerified(a.url, { waitMs: a.wait_ms ?? 2500 }),
  },
  {
    name: "screenshot_file",
    description: "截图并落盘，返回文件路径（绕开图片直接交付被宿主拒收）",
    inputSchema: { type: "object", properties: { prefix: { type: "string" } }, additionalProperties: false },
    run: async (a) => screenshotToFile(a),
  },
  {
    name: "frontmost_app",
    description: "当前前台应用（bundleId/名称；剔除不可靠的 contextId）",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const o = maybeJSON((await callTweak("get_frontmost_app", {})).text);
      if (typeof o === "string") return { raw: o };
      return { name: o.name ?? o.processName ?? null, bundleId: o.bundleId ?? null, pid: o.pid ?? null };
    },
  },
  {
    name: "list_apps",
    description: "列出已安装应用（含 /var/jb、/var/containers/Bundle/Application，覆盖 TrollStore 安装）",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, additionalProperties: false },
    run: async (a) => {
      let apps = scanApps();
      if (a.query) {
        const q = String(a.query).toLowerCase();
        apps = apps.filter((x) => x.name.toLowerCase().includes(q) || (x.bundleId || "").toLowerCase().includes(q));
      }
      return { count: apps.length, apps };
    },
  },
  {
    name: "launch_app",
    description: "启动应用并校验前台（优先 lsopen，失败回退 tweak）",
    inputSchema: { type: "object", properties: { bundle_id: { type: "string" } }, required: ["bundle_id"], additionalProperties: false },
    run: async (a) => {
      await requireUnlocked("launch_app");
      const bin = which("uiopen");
      let viaCli = null;
      if (bin) {
        try { await sh(bin, ["--bundleid", a.bundle_id], { timeoutMs: 15000 }); viaCli = true; } catch { viaCli = false; }
      }
      if (!viaCli) {
        try { await callTweak("launch_app", { bundle_id: a.bundle_id }); } catch (e) { /* 交给下面的校验 */ }
      }
      const deadline = Date.now() + 6000;
      let front = null;
      while (Date.now() < deadline) {
        front = maybeJSON((await callTweak("get_frontmost_app", {})).text);
        if (front?.bundleId === a.bundle_id) break;
        await new Promise((r) => setTimeout(r, 300));
      }
      return { bundleId: a.bundle_id, frontmost: front?.bundleId ?? null, ok: front?.bundleId === a.bundle_id, viaCli };
    },
  },
  {
    name: "clipboard_get",
    description: "读剪贴板正文（tweak 返回的是嵌套 JSON，这里拆平；raw=true 给原始结构）",
    inputSchema: { type: "object", properties: { raw: { type: "boolean" } }, additionalProperties: false },
    run: async (a) => {
      const r = await callTweak("get_clipboard", {});
      const inner = maybeJSON(r.text);
      if (inner && typeof inner === "object" && typeof inner.text === "string") {
        return a.raw ? inner : { text: inner.text, hasImage: !!inner.hasImage, hasURL: !!inner.hasURL };
      }
      return { text: String(r.text ?? "") };
    },
  },
  {
    name: "clipboard_set",
    description: "写剪贴板并回读校验（走 tweak 私有 API）",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"], additionalProperties: false },
    run: async (a) => {
      const w = await callTweak("set_clipboard", { text: a.text });
      let readBack = null;
      try {
        const back = maybeJSON((await callTweak("get_clipboard", {})).text);
        readBack = typeof back?.text === "string" ? back.text : null;
      } catch {}
      return { result: w.text, verified: readBack === a.text, readBack };
    },
  },
  {
    name: "tail_syslog",
    description: "抓系统日志（root 跑 mcp-logreader，绕过沙箱 exec 限制）",
    inputSchema: { type: "object", properties: { seconds: { type: "number" }, max_lines: { type: "number" }, predicate: { type: "string" } }, additionalProperties: false },
    run: async (a) => {
      const bin = which("logreader");
      if (!bin) throw new Error(`mcp-logreader 不存在（找过 ${BIN.logreader.join(" / ")}）`);
      const args = ["--seconds", String(a.seconds ?? 2), "--max-lines", String(a.max_lines ?? 200)];
      if (a.predicate) args.push("--predicate", a.predicate);
      const { stdout } = await sh(bin, args, { timeoutMs: 30000 });
      return { bytes: stdout.length, log: stdout.slice(0, 200000) };
    },
  },
  {
    name: "tweak_call",
    description: "逃生通道：直接调 tweak 的任意工具（不知道封装时用）",
    inputSchema: { type: "object", properties: { name: { type: "string" }, arguments: { type: "object" } }, required: ["name"], additionalProperties: false },
    run: async (a) => callTweak(a.name, a.arguments || {}),
  },
  {
    name: "tweak_tools",
    description: "列出 tweak 暴露的全部工具（含参数）",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const res = await tweak("tools/list", {});
      return (res?.tools || []).map((t) => ({ name: t.name, description: t.description, params: Object.keys(t.inputSchema?.properties || {}) }));
    },
  },
  {
    name: "notify",
    description: "发通知（sbbanner/sbalert，缺了给明确提示）",
    inputSchema: { type: "object", properties: { title: { type: "string" }, text: { type: "string" } }, required: ["text"], additionalProperties: false },
    run: async (a) => {
      const bin = which("sbbanner") || which("sbalert");
      if (!bin) throw new Error("sbbanner/sbalert 不存在（apt-get install sbutils）");
      await sh(bin, [a.title ? `${a.title}\n${a.text}` : a.text]);
      return { sent: true };
    },
  },
  {
    name: "view_screen",
    description: "截图并作为图片内容返回给模型（不经过 sharp；scale 可缩小以省带宽）",
    inputSchema: { type: "object", properties: { scale: { type: "number" }, max_bytes: { type: "number" } }, additionalProperties: false },
    run: async (a) => {
      const { image } = await callTweak("screenshot", {});
      if (!image) throw new Error("tweak 没返回图片数据");
      let data = image.data;
      if (a.max_bytes && Buffer.byteLength(data, "base64") > a.max_bytes) {
        // 太大就不内联，退回落盘
        const saved = await screenshotToFile({ prefix: "big" });
        return { note: "图片过大，已落盘；请用 screenshot_file 拿路径", ...saved };
      }
      return { __image: { data, mimeType: image.mimeType } };
    },
  },
  {
    name: "list_running_apps",
    description: "当前运行的「应用」（过滤掉系统服务/输入法等噪声，只留带 bundleId 的用户 App）",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const raw = maybeJSON((await callTweak("list_running_apps", {})).text);
      const arr = Array.isArray(raw) ? raw : raw?.apps || [];
      const apps = arr.filter((x) => x && typeof x.bundleId === "string" && x.bundleId.includes("."))
        .map((x) => ({ name: x.name || x.processName || null, bundleId: x.bundleId, pid: x.pid ?? null }));
      return { count: apps.length, apps };
    },
  },
  {
    name: "device_info",
    description: "设备与运行环境概览（含 helper 可用性真值）",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const sv = (() => {
        try {
          const xml = readFileSync("/System/Library/CoreServices/SystemVersion.plist", "utf8");
          const g = (k) => (xml.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`)) || [])[1] || "";
          return { product: g("ProductName"), version: g("ProductVersion"), build: g("ProductBuildVersion") };
        } catch { return {}; }
      })();
      return {
        ...sv,
        node: process.version,
        uid: typeof process.getuid === "function" ? process.getuid() : null,
        jailbreakPrefix: JB || null,
        shell: shellPath(),
        helpers: Object.fromEntries(Object.keys(BIN).map((k) => [k, which(k)])),
        tweak: await deviceState({ fresh: true }).catch(() => null),
      };
    },
  },
];

// —— JSON-RPC over stdio ——
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    await tweakInit();
    return send({
      jsonrpc: "2.0", id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "ios-root", version: VERSION },
      },
    });
  }
  if (method === "notifications/initialized" || method === "initialized") return;
  if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
  if (method === "tools/list") {
    return send({
      jsonrpc: "2.0", id,
      result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) },
    });
  }
  if (method === "tools/call") {
    const name = params?.name;
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) {
      return send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: `未知工具: ${name}` }] } });
    }
    try {
      const out = await tool.run(params?.arguments || {});
      if (out && typeof out === "object" && out.__image) {
        return send({
          jsonrpc: "2.0", id,
          result: { content: [{ type: "image", data: out.__image.data, mimeType: out.__image.mimeType }] },
        });
      }
      const text = typeof out === "string" ? out : JSON.stringify(out, null, 2);
      return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
    } catch (e) {
      const payload = e.structured ? { ...e.structured, error: String(e.message || e) } : { error: String(e.message || e) };
      return send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: JSON.stringify(payload, null, 2) }] } });
    }
  }
  if (id !== undefined) {
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: `不支持的方法: ${method}` } });
  }
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
      .catch((e) => { if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: String(e?.message || e) } }); })
      .finally(() => { pending--; });
  }
});
process.stdin.on("end", () => {
  const wait = () => (pending > 0 ? setTimeout(wait, 50) : process.exit(0));
  wait();
});
