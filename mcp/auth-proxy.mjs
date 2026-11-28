#!/usr/bin/env node
// auth-proxy.mjs —— 127.0.0.1:3081 → 3080 的本地反向代理
//
// 为什么需要它：dsh 每次启动都会生成新的 token，宿主 App 只能靠读文件拿 URL；
// 而 TrollStore 装的 App 是沙盒的，读不到系统路径，于是引擎一重启就要重新配对。
// 这里把“换 token”这件事收到代理里：宿主 App 永远打开 http://127.0.0.1:3081/，
// 代理自己去引擎换 cookie，401 时自动重换。
//
// 依赖：node 内置 http/net（不依赖任何 npm 包）。以 root 跑，监听 loopback。

import http from "node:http";
import net from "node:net";
import { existsSync, readFileSync } from "node:fs";

const LISTEN_PORT = Number(process.env.DSH_PROXY_PORT || 3081);
const UP_HOST = "127.0.0.1";
const UP_PORT = Number(process.env.DSH_UPSTREAM_PORT || 3080);
const WEB_URL_FILE = "/var/mobile/Library/dsh/.web-url";

let cookie = "";
let cookieAt = 0;

function tokenURL() {
  try {
    const u = readFileSync(WEB_URL_FILE, "utf8").trim();
    if (u.startsWith("http")) return u;
  } catch {}
  return `http://${UP_HOST}:${UP_PORT}/`;
}

/** 去引擎换一次会话 cookie（拦下 303，只取 Set-Cookie） */
async function refreshCookie(force = false) {
  if (!force && cookie && Date.now() - cookieAt < 5 * 60 * 1000) return cookie;
  const url = tokenURL();
  try {
    const r = await fetch(url, { redirect: "manual" });
    const sc = r.headers.get("set-cookie");
    if (sc) {
      cookie = sc.split(";")[0];
      cookieAt = Date.now();
      console.log(`[proxy] cookie refreshed (status ${r.status})`);
    } else {
      console.log(`[proxy] no set-cookie (status ${r.status})`);
    }
  } catch (e) {
    console.log("[proxy] refresh failed:", String(e.message || e));
  }
  return cookie;
}

function upstreamHeaders(req, extraCookie) {
  const h = { ...req.headers };
  delete h.host;
  delete h.connection;
  h.host = `${UP_HOST}:${UP_PORT}`;
  // 引擎对写操作做同源校验（看 Origin/Referer 的 host 是否等于 Host）。
  // 客户端看到的是 3081，透传过去就会被判成跨源 → 401。这里统一改写成上游地址。
  const origin = `http://${UP_HOST}:${UP_PORT}`;
  if (h.origin) h.origin = origin;
  if (h.referer) h.referer = String(h.referer).replace(`http://127.0.0.1:${LISTEN_PORT}`, origin);
  if (h["x-forwarded-host"]) delete h["x-forwarded-host"];
  if (h["x-forwarded-proto"]) delete h["x-forwarded-proto"];
  if (extraCookie) {
    // 保留客户端自己的 cookie，再叠加会话 cookie
    const client = h.cookie ? `${h.cookie}; ` : "";
    h.cookie = client + extraCookie;
  }
  return h;
}

const server = http.createServer(async (req, res) => {
  await refreshCookie();
  const proxy = http.request(
    { host: UP_HOST, port: UP_PORT, method: req.method, path: req.url, headers: upstreamHeaders(req, cookie) },
    (up) => {
      if (up.statusCode === 401) {
        // 会话失效（引擎重启）→ 强制重换一次再让客户端重试
        refreshCookie(true).catch(() => {});
      }
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    },
  );
  proxy.on("error", (e) => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end(`proxy error: ${e.message}`);
  });
  req.pipe(proxy);
});

// WebSocket / 升级请求：原样透传握手（带上会话 cookie）
server.on("upgrade", async (req, socket, head) => {
  await refreshCookie();
  const up = net.connect(UP_PORT, UP_HOST, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    const h = upstreamHeaders(req, cookie);
    for (const [k, v] of Object.entries(h)) {
      if (Array.isArray(v)) for (const one of v) lines.push(`${k}: ${one}`);
      else if (v !== undefined) lines.push(`${k}: ${v}`);
    }
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
});

server.listen(LISTEN_PORT, "127.0.0.1", () => {
  console.log(`[proxy] listening on http://127.0.0.1:${LISTEN_PORT} -> ${UP_HOST}:${UP_PORT}`);
  refreshCookie(true).catch(() => {});
});
