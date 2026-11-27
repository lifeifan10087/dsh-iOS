// fetch-http.cjs —— 用 node:http/https 实现的 Fetch 子集，替代 undici
//
// 为什么需要：越狱 iOS 上只能用 `--jitless`，而 jitless 下没有 WebAssembly；
// undici（npm 的 8.x 和 Node 内置的都在内）解析 HTTP/1.1 要靠 WASM 版的 llhttp，
// 所以 `fetch` 根本发不出请求。dsh 的模型调用走 globalThis.fetch（见 dsh-llm-deepseek
// 的 `this.fetchImpl = options.fetch ?? globalThis.fetch`），SSE 又是
// `response.body.pipeThrough(new TextDecoderStream())`，所以这里必须给出：
//   · 真 ReadableStream 的 body（web streams，Node 自带）
//   · 自动解压 gzip/deflate/br（undici 也这么做，调用方不会自己解）
//   · redirect: "error"/"manual"/"follow"
//   · AbortSignal 支持（dsh 会 abort 掉超时的模型请求）
//
// 覆盖范围：标准 fetch 的常用面 + Headers/Request/Response/FormData。
// 不支持的：HTTP/2、代理（ProxyAgent）、cookie jar、fetch 的 dispatcher 选项。

"use strict";

const http = require("node:http");
const https = require("node:https");
const zlib = require("node:zlib");
const { Readable } = require("node:stream");
const { URL, URLSearchParams } = require("node:url");

const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308]);

function normalizeName(name) {
  return String(name).toLowerCase();
}

class Headers {
  constructor(init) {
    this._map = new Map();
    if (init instanceof Headers) {
      for (const [k, v] of init) this.append(k, v);
    } else if (Array.isArray(init)) {
      for (const [k, v] of init) this.append(k, v);
    } else if (init && typeof init === "object") {
      for (const [k, v] of Object.entries(init)) {
        if (v === undefined || v === null) continue;
        this.append(k, Array.isArray(v) ? v.join(", ") : v);
      }
    }
  }
  append(name, value) {
    const k = normalizeName(name);
    const prev = this._map.get(k);
    this._map.set(k, prev === undefined ? String(value) : `${prev}, ${value}`);
  }
  set(name, value) { this._map.set(normalizeName(name), String(value)); }
  get(name) { const v = this._map.get(normalizeName(name)); return v === undefined ? null : v; }
  has(name) { return this._map.has(normalizeName(name)); }
  delete(name) { this._map.delete(normalizeName(name)); }
  forEach(cb, thisArg) { for (const [k, v] of this._map) cb.call(thisArg, v, k, this); }
  entries() { return this._map.entries(); }
  keys() { return this._map.keys(); }
  values() { return this._map.values(); }
  [Symbol.iterator]() { return this._map.entries(); }
  getSetCookie() { return this.get("set-cookie") ? [this.get("set-cookie")] : []; }
}

function headersToNode(headers) {
  const out = {};
  for (const [k, v] of new Headers(headers)) out[k] = v;
  return out;
}

class Request {
  constructor(input, init = {}) {
    if (input instanceof Request) {
      this.url = input.url;
      this.method = init.method || input.method;
      this.headers = new Headers(init.headers || input.headers);
      this._body = init.body !== undefined ? init.body : input._body;
      this.signal = init.signal || input.signal;
    } else {
      this.url = String(input);
      this.method = (init.method || "GET").toUpperCase();
      this.headers = new Headers(init.headers);
      this._body = init.body;
      this.signal = init.signal;
    }
    this.redirect = init.redirect || "follow";
  }
}

// 把 IncomingMessage 转成 web ReadableStream。
// 用 Readable.toWeb（背压/流控都由 Node 处理），但必须给 res 和可能的解压流挂 error
// 监听：dsh 的服务端在响应后常直接关连接，socket 的 ECONNRESET 会以 emit('error')
// 的形式冒出来，没人接就是 uncaughtException（Error: aborted）。
// 已经读到的数据不受影响，所以这里把错误吞掉即可。
function makeBodyStream(res, encoding) {
  const enc = (encoding || "").toLowerCase();
  let src = res;
  if (enc === "gzip" || enc === "x-gzip") src = res.pipe(zlib.createGunzip());
  else if (enc === "deflate") src = res.pipe(zlib.createInflate());
  else if (enc === "br") src = res.pipe(zlib.createBrotliDecompress());

  res.on("error", () => {});
  if (src !== res) src.on("error", () => {});
  res.on("aborted", () => {});

  return Readable.toWeb(src);
}

class Response {
  constructor(body, init = {}) {
    this._body = body; // web ReadableStream | null
    this.status = init.status === undefined ? 200 : init.status;
    this.statusText = init.statusText || "";
    this.headers = new Headers(init.headers);
    this.url = init.url || "";
    this.redirected = !!init.redirected;
    this.ok = this.status >= 200 && this.status < 300;
    this.bodyUsed = false;
    this.type = "default";
  }
  get body() {
    return this.bodyUsed ? null : this._body;
  }
  _take() {
    if (this.bodyUsed) throw new TypeError("body already used");
    this.bodyUsed = true;
    return this._body;
  }
  async arrayBuffer() {
    const stream = this._take();
    if (!stream) return new ArrayBuffer(0);
    const chunks = [];
    for await (const c of stream) chunks.push(Buffer.from(c));
    const buf = Buffer.concat(chunks);
    return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  }
  async text() {
    return Buffer.from(await this.arrayBuffer()).toString("utf8");
  }
  async json() {
    return JSON.parse(await this.text());
  }
  async blob() {
    return new Blob([await this.arrayBuffer()], { type: this.headers.get("content-type") || "" });
  }
  clone() {
    // 简化：clone 只在 body 未被消费时有意义；这里用 tee 拆流
    if (!this._body) return new Response(null, this);
    const [a, b] = this._body.tee();
    const copy = new Response(b, this);
    this._body = a;
    return copy;
  }
}

class FormData {
  constructor() { this._entries = []; }
  append(name, value, filename) { this._entries.push([name, value, filename]); }
  set(name, value, filename) {
    this.delete(name);
    this.append(name, value, filename);
  }
  delete(name) { this._entries = this._entries.filter(([n]) => n !== name); }
  get(name) { const e = this._entries.find(([n]) => n === name); return e ? e[1] : null; }
  getAll(name) { return this._entries.filter(([n]) => n === name).map((e) => e[1]); }
  has(name) { return this._entries.some(([n]) => n === name); }
  entries() { return this._entries.map(([n, v]) => [n, v])[Symbol.iterator](); }
  [Symbol.iterator]() { return this.entries(); }
}

function encodeFormData(fd) {
  const boundary = "----dshFormBoundary" + Math.random().toString(16).slice(2);
  const parts = [];
  for (const [name, value, filename] of fd._entries) {
    if (value instanceof Blob || (value && typeof value.arrayBuffer === "function")) {
      const fn = filename || value.name || "blob";
      parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${fn}"\r\nContent-Type: ${value.type || "application/octet-stream"}\r\n\r\n`));
      parts.push(Buffer.from(value._buffer || []));
      parts.push(Buffer.from("\r\n"));
    } else {
      parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
    }
  }
  parts.push(Buffer.from(`--${boundary}--\r\n`));
  return { body: Buffer.concat(parts), contentType: `multipart/form-data; boundary=${boundary}` };
}

function bodyToBuffer(body) {
  if (body === undefined || body === null) return { buf: null, contentType: null };
  if (typeof body === "string") return { buf: Buffer.from(body), contentType: "text/plain;charset=UTF-8" };
  if (Buffer.isBuffer(body)) return { buf: body, contentType: null };
  if (body instanceof Uint8Array) return { buf: Buffer.from(body), contentType: null };
  if (body instanceof URLSearchParams) {
    return { buf: Buffer.from(body.toString()), contentType: "application/x-www-form-urlencoded;charset=UTF-8" };
  }
  if (body instanceof FormData) {
    const { body: buf, contentType } = encodeFormData(body);
    return { buf, contentType };
  }
  if (typeof body === "object" && typeof body.arrayBuffer === "function") {
    return { buf: Buffer.from(body._buffer || []), contentType: body.type || null };
  }
  return { buf: Buffer.from(String(body)), contentType: null };
}

function fetchOnce(input, init, redirectCount, signal) {
  const req = input instanceof Request ? input : new Request(input, init);
  const url = new URL(req.url);
  const isHttps = url.protocol === "https:";
  const lib = isHttps ? https : http;

  const headers = headersToNode(req.headers);
  const { buf, contentType } = bodyToBuffer(req._body);
  if (buf && !headers["content-type"] && contentType) headers["content-type"] = contentType;
  if (buf) headers["content-length"] = String(buf.length);

  return new Promise((resolve0, reject0) => {
    let settled = false;
    const resolve = (v) => { if (!settled) { settled = true; resolve0(v); } };
    const reject = (e) => { if (!settled) { settled = true; reject0(e); } };
    const nodeReq = lib.request(
      {
        protocol: url.protocol,
        hostname: url.hostname.replace(/^\[|\]$/g, ""),
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method: req.method,
        headers,
        // SNI 需要显式 servername
        servername: isHttps ? url.hostname : undefined,
      },
      (res) => {
        const location = res.headers.location;
        if (REDIRECT_STATUS.has(res.statusCode) && location) {
          // 跳转后这个请求就结束了：摘掉 error 监听，否则 res 被销毁时的
          // ECONNRESET/"aborted" 会把下一次请求的 promise 顶掉
          nodeReq.removeAllListeners("error");
          // 必须留一个空的 error 监听：ClientRequest 在 socket 关闭时会 emit('error')，
          // 没有监听器就会变成 uncaughtException（Error: aborted / ECONNRESET）
          nodeReq.on("error", () => {});
          res.on("error", () => {});
          res.resume();
          res.destroy();
          if (req.redirect === "error") {
            reject(new TypeError(`unexpected redirect to ${location} (redirect: "error")`));
            return;
          }
          if (req.redirect === "manual" || redirectCount >= 5) {
            resolve(
              makeResponse(null, {
                status: res.statusCode,
                statusText: res.statusMessage || "",
                headers: res.headers,
                url: req.url,
              }),
            );
            return;
          }
          const next = new URL(location, req.url).toString();
          // 同源跳转时把 set-cookie 带过去（undici 不做 cookie jar，但 dsh 的
          // token 换 cookie 就是靠这个跳转，不带就会 401）
          const nextHeaders = new Headers(req.headers);
          const setCookie = res.headers["set-cookie"];
          if (setCookie && new URL(next).origin === new URL(req.url).origin) {
            const jar = (Array.isArray(setCookie) ? setCookie : [setCookie])
              .map((c) => String(c).split(";")[0])
              .join("; ");
            const prev = nextHeaders.get("cookie");
            nextHeaders.set("cookie", prev ? `${prev}; ${jar}` : jar);
          }
          const nextInit = {
            method: req.method,
            headers: nextHeaders,
            body: req._body,
            redirect: req.redirect,
            signal,
          };
          fetchOnce(next, nextInit, redirectCount + 1, signal).then(resolve, reject);
          return;
        }
        const encoding = res.headers["content-encoding"];
        let stream;
        try {
          stream = makeBodyStream(res, encoding);
        } catch (e) {
          reject(e);
          return;
        }
        const outHeaders = new Headers();
        for (const [k, v] of Object.entries(res.headers)) {
          if (k === "content-encoding") continue; // 已解压，别让调用方再解一次
          if (k === "content-length") continue;
          if (Array.isArray(v)) for (const one of v) outHeaders.append(k, one);
          else if (v !== undefined) outHeaders.set(k, v);
        }
        resolve(
          makeResponse(stream, {
            status: res.statusCode,
            statusText: res.statusMessage || "",
            headers: outHeaders,
            url: req.url,
          }),
        );
      },
    );

    nodeReq.on("error", (err) => reject(Object.assign(err, { name: err.name })));
    if (signal) {
      if (signal.aborted) {
        nodeReq.destroy(new Error("aborted"));
        reject(signal.reason || new Error("aborted"));
        return;
      }
      const onAbort = () => nodeReq.destroy(signal.reason || new Error("aborted"));
      signal.addEventListener("abort", onAbort, { once: true });
      nodeReq.on("close", () => signal.removeEventListener("abort", onAbort));
    }
    nodeReq.setTimeout(0);
    if (buf) nodeReq.end(buf);
    else nodeReq.end();
  });
}

function makeResponse(body, init) {
  const Native = typeof globalThis.Response === "function" ? globalThis.Response : Response;
  try {
    return new Native(body, init);
  } catch {
    return new Response(body, init);
  }
}

function fetch(input, init = {}) {
  const signal = init.signal || (input instanceof Request ? input.signal : undefined);
  return fetchOnce(input, init, 0, signal);
}

// —— 只在不是原生实现时覆盖。原生 fetch 在 jitless 下用不了，所以这里基本总是覆盖。
function install(target = globalThis) {
  // 只换 fetch。Headers/Request/Response 保持 Node 原生的（jitless 下它们不需要 WASM，
  // 只有 dispatcher 的 llhttp 才需要），这样 dsh 里 `instanceof Response`、
  // 服务端写响应这些路径都不会被我们的实现带偏。
  target.fetch = fetch;
  if (typeof target.Headers === "undefined") target.Headers = Headers;
  if (typeof target.Request === "undefined") target.Request = Request;
  if (typeof target.Response === "undefined") target.Response = Response;
  if (typeof target.FormData === "undefined") target.FormData = FormData;
  return { fetch, Headers, Request, Response, FormData };
}

module.exports = { fetch, Headers, Request, Response, FormData, install };
